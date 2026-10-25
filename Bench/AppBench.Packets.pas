// AppBench: binary packets in a RawByteString, written and read through interfaces
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// The writer appends raw values to a RawByteString whose length is its capacity. The capacity grows
// by the size of the pending data and then rounds up: to 16, 256 or 1024 bytes, and above 1 KB by
// another 16 KB; Flush cuts the string down to the data. So a small packet costs a 16-byte string,
// a resize to 256 bytes and a final shrink.
//
// The reader takes the packet by reference, and its first read copies the packet: the reader passes
// a character of the shared string to Move, and taking that address makes the compiler call
// UniqueString. The copy is part of the reproduced workload.
//
// Format: Integer, Int32, Int64 and Double as their bytes; UTF-16 text as its code units, with the
// length written separately by the caller; a Variant as its UInt16 type followed by nothing for
// Null, an Int32 for varInteger and a UInt32 length with the code units for varUString.
//
// The protected FPadding fields bring the instances to the size of their counterparts.

unit AppBench.Packets;

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

interface

uses
  System.SysUtils;

type
  EPacketError = class(Exception);

  IPacketWriter = interface
    ['{8E0C7B14-5D2A-4F63-9B71-3C5E2A94D610}']
    procedure WriteInteger(Value: Integer);
    procedure WriteInt32(Value: Int32);
    procedure WriteInt64(Value: Int64);
    procedure WriteDouble(Value: Double);
    procedure WriteUtf16String(const Value: string; Length: Integer);
    procedure WriteVariant(const Value: Variant);
    procedure Write(Data: Pointer; Size: NativeUInt);
    // Cuts the string down to the data written
    procedure Flush;
    function Data: RawByteString;
  end;

  IPacketReader = interface
    ['{2F6D9A31-7C48-4E05-A1B3-94E7C25D8F27}']
    function ReadInteger: Integer;
    function ReadInt32: Int32;
    function ReadInt64: Int64;
    function ReadDouble: Double;
    function ReadUtf16String(Count: NativeUInt): string;
    function ReadVariant: Variant;
    // Up to Size bytes; 0 at the end of the packet
    function Read(Data: Pointer; Size: NativeUInt): NativeUInt;
  end;

  TPacketWriter = class(TInterfacedObject, IPacketWriter)
  private
    FData: RawByteString;
    FLength: NativeUInt;
    FCapacity: NativeUInt;
    procedure Grow(Size: NativeUInt);
  protected
    FPadding: array[0..6] of Pointer;
  public
    procedure WriteInteger(Value: Integer);
    procedure WriteInt32(Value: Int32);
    procedure WriteInt64(Value: Int64);
    procedure WriteDouble(Value: Double);
    procedure WriteUtf16String(const Value: string; Length: Integer);
    procedure WriteVariant(const Value: Variant);
    procedure Write(Data: Pointer; Size: NativeUInt);
    procedure Flush;
    function Data: RawByteString;
  end;

  TPacketReader = class(TInterfacedObject, IPacketReader)
  private
    FData: RawByteString;
    FLength: NativeUInt;
    FPosition: NativeUInt;
    procedure ReadExact(Data: Pointer; Size: NativeUInt);
  protected
    FPadding: array[0..6] of Pointer;
  public
    constructor Create(const Data: RawByteString);
    destructor Destroy; override;
    function ReadInteger: Integer;
    function ReadInt32: Int32;
    function ReadInt64: Int64;
    function ReadDouble: Double;
    function ReadUtf16String(Count: NativeUInt): string;
    function ReadVariant: Variant;
    function Read(Data: Pointer; Size: NativeUInt): NativeUInt;
  end;

implementation

uses
  System.Variants;

{ TPacketWriter }

procedure TPacketWriter.Grow(Size: NativeUInt);
begin
  if Size > FCapacity then
  begin
    FCapacity := FCapacity + Size;
    if FCapacity < 16 then
      FCapacity := 16
    else if FCapacity < 256 then
      FCapacity := 256
    else if FCapacity < 1024 then
      FCapacity := 1024
    else
      FCapacity := FCapacity + 16 * 1024;
    SetLength(FData, FCapacity);
  end;
end;

procedure TPacketWriter.Write(Data: Pointer; Size: NativeUInt);
begin
  if Size = 0 then
    Exit;
  Grow(FLength + Size);
  Move(Data^, FData[FLength + 1], Size);
  Inc(FLength, Size);
end;

procedure TPacketWriter.WriteInteger(Value: Integer);
begin
  Write(@Value, SizeOf(Value));
end;

procedure TPacketWriter.WriteInt32(Value: Int32);
begin
  Write(@Value, SizeOf(Value));
end;

procedure TPacketWriter.WriteInt64(Value: Int64);
begin
  Write(@Value, SizeOf(Value));
end;

procedure TPacketWriter.WriteDouble(Value: Double);
begin
  Write(@Value, SizeOf(Value));
end;

procedure TPacketWriter.WriteUtf16String(const Value: string; Length: Integer);
begin
  Write(Pointer(Value), NativeUInt(Length) * SizeOf(Char));
end;

procedure TPacketWriter.WriteVariant(const Value: Variant);
var
  VType: Word;
  Len: Cardinal;
begin
  VType := TVarData(Value).VType;
  Write(@VType, SizeOf(VType));
  case VType of
    varEmpty, varNull: ;
    varInteger:
      WriteInt32(TVarData(Value).VInteger);
    varUString:
      begin
        Len := Length(UnicodeString(TVarData(Value).VUString));
        Write(@Len, SizeOf(Len));
        Write(TVarData(Value).VUString, Len * SizeOf(Char));
      end;
  else
    raise EPacketError.CreateFmt('Variant type %d is not supported', [VType]);
  end;
end;

procedure TPacketWriter.Flush;
begin
  SetLength(FData, FLength);
  FCapacity := FLength;
end;

function TPacketWriter.Data: RawByteString;
begin
  Result := FData;
end;

{ TPacketReader }

constructor TPacketReader.Create(const Data: RawByteString);
begin
  inherited Create;
  FData := Data;
  FLength := Length(Data);
end;

destructor TPacketReader.Destroy;
begin
  FData := '';
  inherited;
end;

function TPacketReader.Read(Data: Pointer; Size: NativeUInt): NativeUInt;
begin
  if FPosition >= FLength then
    Exit(0);
  Result := FLength - FPosition;
  if Size < Result then
    Result := Size;
  Move(FData[FPosition + 1], Data^, Result);
  Inc(FPosition, Result);
end;

procedure TPacketReader.ReadExact(Data: Pointer; Size: NativeUInt);
begin
  if (Size > 0) and (Read(Data, Size) <> Size) then
    raise EPacketError.Create('Unexpected end of packet');
end;

function TPacketReader.ReadInteger: Integer;
begin
  ReadExact(@Result, SizeOf(Result));
end;

function TPacketReader.ReadInt32: Int32;
begin
  ReadExact(@Result, SizeOf(Result));
end;

function TPacketReader.ReadInt64: Int64;
begin
  ReadExact(@Result, SizeOf(Result));
end;

function TPacketReader.ReadDouble: Double;
begin
  ReadExact(@Result, SizeOf(Result));
end;

function TPacketReader.ReadUtf16String(Count: NativeUInt): string;
begin
  SetString(Result, nil, Count);
  ReadExact(Pointer(Result), Count * SizeOf(Char));
end;

function TPacketReader.ReadVariant: Variant;
var
  VType: Word;
  Len: Cardinal;
  S: string;
begin
  ReadExact(@VType, SizeOf(VType));
  case VType of
    varEmpty:
      Result := Unassigned;
    varNull:
      Result := Null;
    varInteger:
      Result := ReadInt32;
    varUString:
      begin
        ReadExact(@Len, SizeOf(Len));
        SetLength(S, Len);
        ReadExact(Pointer(S), Len * SizeOf(Char));
        Result := S;
      end;
  else
    raise EPacketError.CreateFmt('Variant type %d is not supported', [VType]);
  end;
end;

end.
