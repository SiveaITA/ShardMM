// AppBench: a JSON DOM with a buffered writer and a streaming parser
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// The DOM reproduces the allocations of a production JSON library. Nodes are reference-counted
// objects (TInterfacedObject) of 48-96 bytes; object properties and array items live in dynamic
// arrays grown by 4 up to 8 entries and doubled after that; iterating an array allocates an
// enumerator object.
//
// ToUTF8 creates a packet writer and a 213 KB writer object: the 64 KB output buffer and the mode
// and counter stacks for 16 K nesting levels live inside the object, and the RTL zero-fills all of
// it on every creation. A string goes through a UTF-8 work array of the writer and is preceded by a
// flush of the buffer, so the packet writer receives two writes per string.
//
// Load creates a packet reader, a 20 KB parser object (a 16 KB input buffer and a 4 KB dispatch
// table filled on creation), a 1 KB work array for text and a handler with an 8-entry stack. The
// parser copies every key and string into the work array, and the handler decodes it from UTF-8
// into a new string: SetString of the byte length, Utf8ToUnicode, then SetLength down to the
// decoded length. The key string of the handler is cleared and allocated anew for every key.
//
// The protected FPadding fields bring the instances to the size of their counterparts.

unit AppBench.Json;

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

interface

uses
  System.SysUtils, AppBench.Packets;

type
  EJsonError = class(Exception);

  TJsonType = (jtNull, jtBoolean, jtInteger, jtReal, jtString, jtArray, jtObject);

  TJsonValue = class(TInterfacedObject)
  private
    FContainer: TJsonValue;
    FType: TJsonType;
  public
    constructor Create(AType: TJsonType);
    // The text in UTF-8, without whitespace
    function ToUTF8: RawByteString;
    // The caller owns the result
    class function Load(const Data: RawByteString): TJsonValue;
    property Container: TJsonValue read FContainer;
    property JsonType: TJsonType read FType;
  end;

  TJsonNull = class(TJsonValue)
  public
    constructor Create;
  end;

  TJsonBoolean = class(TJsonValue)
  private
    FValue: Boolean;
  public
    constructor Create(AValue: Boolean);
    property Value: Boolean read FValue;
  end;

  TJsonInteger = class(TJsonValue)
  private
    FValue: Int64;
  public
    constructor Create(AValue: Int64);
    property Value: Int64 read FValue;
  end;

  TJsonReal = class(TJsonValue)
  private
    FValue: Extended;
  public
    constructor Create(AValue: Extended);
    property Value: Extended read FValue;
  end;

  TJsonString = class(TJsonValue)
  private
    FValue: string;
  public
    constructor Create(const AValue: string); overload;
    // Decodes Len bytes of UTF-8
    constructor Create(Data: PAnsiChar; Len: Integer); overload;
    property Value: string read FValue;
  end;

  TJsonProperty = record
    Name: string;
    Value: TJsonValue;
  end;

  TJsonObject = class(TJsonValue)
  private
    FProps: TArray<TJsonProperty>;
    FCapacity: NativeInt;
    FCount: NativeInt;
    function IndexOf(const Name: string): NativeInt;
    function GetValue(const Name: string): TJsonValue;
    procedure SetValue(const Name: string; Value: TJsonValue);
    function GetProp(Index: NativeInt): TJsonProperty; inline;
  protected
    FPadding: array[0..2] of Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    property Count: NativeInt read FCount;
    property Props[Index: NativeInt]: TJsonProperty read GetProp;
    // Lookups by name scan the properties: objects of the workload have six at most
    property Values[const Name: string]: TJsonValue read GetValue write SetValue; default;
  end;

  IJsonEnumerator = interface
    ['{5B2E8C71-0A4F-4D93-8E16-7F3A9C2B4D58}']
    function GetCurrent: TJsonValue;
    function MoveNext: Boolean;
    property Current: TJsonValue read GetCurrent;
  end;

  TJsonArray = class(TJsonValue)
  private
    FItems: TArray<TJsonValue>;
    FCapacity: NativeInt;
    FCount: NativeInt;
    function GetItem(Index: NativeInt): TJsonValue; inline;
  protected
    FPadding: array[0..1] of Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(Value: TJsonValue);
    // A new enumerator object for every loop
    function GetEnumerator: IJsonEnumerator;
    property Count: NativeInt read FCount;
    property Items[Index: NativeInt]: TJsonValue read GetItem; default;
  end;

  TJsonArrayEnumerator = class(TInterfacedObject, IJsonEnumerator)
  private
    FItems: TArray<TJsonValue>;
    FIndex: NativeInt;
    FCount: NativeInt;
  protected
    FPadding: Pointer;
  public
    constructor Create(const Items: TArray<TJsonValue>; Count: NativeInt);
    function GetCurrent: TJsonValue;
    function MoveNext: Boolean;
  end;

  TJsonWriter = class
  private const
    BufferSize = 64 * 1024;
    MaxDepth = 16 * 1024;
  private type
    TMode = (wmValue, wmArray, wmObject);
  private
    // The reserve past BufferSize holds the longest escape, \u00XX, which PutUtf8 writes unchecked
    FBuffer: array[0..BufferSize + 8] of AnsiChar;
    FCurrent: PAnsiChar;
    FStart: PAnsiChar;
    FOutput: IPacketWriter;
    FModes: array[0..MaxDepth] of TMode;
    FCounts: array[0..MaxDepth] of NativeUInt;
    FDepth: NativeUInt;
    FText: TArray<AnsiChar>;
    FTextLength: Integer;
    procedure Flush; inline;
    procedure CheckBuffer(Rest: NativeUInt); inline;
    procedure PutChar(Ch: AnsiChar); inline;
    procedure PutUtf8(Data: PAnsiChar; Len: Integer);
    procedure PutString(const Value: string);
    procedure BeginValue; inline;
    procedure Push(Mode: TMode);
    procedure Pop;
    procedure WriteArray(Value: TJsonArray);
    procedure WriteObject(Value: TJsonObject);
  public
    constructor Create(const Output: IPacketWriter);
    procedure BeginDocument;
    procedure EndDocument;
    procedure BeginArray;
    procedure EndArray;
    procedure BeginObject;
    procedure EndObject;
    procedure WriteKey(const Name: string);
    procedure WriteText(const Value: string);
    procedure WriteInteger(Value: Int64);
    procedure WriteReal(Value: Extended);
    procedure WriteBoolean(Value: Boolean);
    procedure WriteNull;
    procedure Write(Value: TJsonValue);
  end;

  IJsonHandler = interface
    ['{C41A7E39-6B5D-4F28-93C0-1D8E5A7B2F64}']
    procedure BeginArray;
    procedure EndArray;
    procedure BeginObject;
    procedure EndObject;
    // Data is UTF-8 without escapes; it is valid only during the call
    procedure Key(Data: PAnsiChar; Len: Integer);
    procedure Text(Data: PAnsiChar; Len: Integer);
    procedure IntegerValue(Value: Int64);
    procedure RealValue(Value: Extended);
    procedure BooleanValue(Value: Boolean);
    procedure NullValue;
    // The root value; the handler no longer owns it
    function ExtractValue: TJsonValue;
  end;

  TJsonHandler = class(TInterfacedObject, IJsonHandler)
  private
    FCurrent: TJsonValue;
    FValue: TJsonValue;
    FStack: TArray<TJsonValue>;
    FStackCapacity: NativeInt;
    FStackCount: NativeInt;
    FIsProperty: Boolean;
    FPropertyName: string;
    procedure Push;
    function AddValue(Value: TJsonValue): TJsonValue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginArray;
    procedure EndArray;
    procedure BeginObject;
    procedure EndObject;
    procedure Key(Data: PAnsiChar; Len: Integer);
    procedure Text(Data: PAnsiChar; Len: Integer);
    procedure IntegerValue(Value: Int64);
    procedure RealValue(Value: Extended);
    procedure BooleanValue(Value: Boolean);
    procedure NullValue;
    function ExtractValue: TJsonValue;
  end;

  TJsonParser = class
  private const
    BufferCapacity = 16 * 1024;
  private type
    TStep = procedure of object;
  private
    FInput: IPacketReader;
    FHandler: IJsonHandler;
    FText: TArray<AnsiChar>;
    FTextCapacity: NativeUInt;
    // At the end of the input FBuffer[0] is #0 and FEOF is set
    FBuffer: array[0..BufferCapacity] of AnsiChar;
    FBufferSize: NativeUInt;
    FPosition: NativeUInt;
    FCh: AnsiChar;
    FEOF: Boolean;
    // The parse step by the first character of a value
    FSteps: array[AnsiChar] of TStep;
    procedure Next; inline;
    procedure Refill;
    procedure SkipSpace; inline;
    procedure Expect(Ch: AnsiChar);
    procedure Unexpected;
    procedure GrowText;
    procedure PutCodePoint(var Len: NativeUInt; CodePoint: Cardinal);
    function ReadHex4: Cardinal;
    // The string at FCh into FText; the result is its length in bytes
    function ScanString: NativeUInt;
    procedure ParseValue;
    procedure ParseObject;
    procedure ParseArray;
    procedure ParseString;
    procedure ParseNumber;
    procedure ParseTrue;
    procedure ParseFalse;
    procedure ParseNull;
    procedure ParseWord(const Word: AnsiString);
  protected
    FPadding: array[0..1] of Pointer;
  public
    constructor Create;
    procedure Parse(const Input: IPacketReader; const Handler: IJsonHandler);
  end;

implementation

var
  JsonFormat: TFormatSettings;

// The out parameter clears S before the call, so every call allocates a new string
procedure DecodeUtf8(Data: PAnsiChar; Len: Integer; out S: string);
begin
  if Len = 0 then
    Exit;
  SetString(S, nil, Len);
  Len := Utf8ToUnicode(Pointer(S), Len + 1, Data, Len);
  if Len > 0 then
    SetLength(S, Len - 1)
  else
    S := '';
end;

function Power10(N: Integer): Extended;
var
  Base: Extended;
begin
  Result := 1;
  Base := 10;
  while N > 0 do
  begin
    if Odd(N) then
      Result := Result * Base;
    Base := Base * Base;
    N := N shr 1;
  end;
end;

{ TJsonValue }

constructor TJsonValue.Create(AType: TJsonType);
begin
  inherited Create;
  FType := AType;
end;

function TJsonValue.ToUTF8: RawByteString;
var
  Output: IPacketWriter;
  Writer: TJsonWriter;
begin
  Output := TPacketWriter.Create;
  Writer := TJsonWriter.Create(Output);
  try
    Writer.BeginDocument;
    Writer.Write(Self);
    Writer.EndDocument;
  finally
    Writer.Free;
  end;
  Result := Output.Data;
end;

class function TJsonValue.Load(const Data: RawByteString): TJsonValue;
var
  Input: IPacketReader;
  Parser: TJsonParser;
  Handler: IJsonHandler;
begin
  Input := TPacketReader.Create(Data);
  Parser := TJsonParser.Create;
  try
    Handler := TJsonHandler.Create;
    Parser.Parse(Input, Handler);
    Result := Handler.ExtractValue;
  finally
    Parser.Free;
  end;
end;

{ TJsonNull }

constructor TJsonNull.Create;
begin
  inherited Create(jtNull);
end;

{ TJsonBoolean }

constructor TJsonBoolean.Create(AValue: Boolean);
begin
  inherited Create(jtBoolean);
  FValue := AValue;
end;

{ TJsonInteger }

constructor TJsonInteger.Create(AValue: Int64);
begin
  inherited Create(jtInteger);
  FValue := AValue;
end;

{ TJsonReal }

constructor TJsonReal.Create(AValue: Extended);
begin
  inherited Create(jtReal);
  FValue := AValue;
end;

{ TJsonString }

constructor TJsonString.Create(const AValue: string);
begin
  inherited Create(jtString);
  FValue := AValue;
end;

constructor TJsonString.Create(Data: PAnsiChar; Len: Integer);
begin
  inherited Create(jtString);
  DecodeUtf8(Data, Len, FValue);
end;

{ TJsonObject }

constructor TJsonObject.Create;
begin
  inherited Create(jtObject);
end;

destructor TJsonObject.Destroy;
var
  I: NativeInt;
begin
  for I := 0 to FCount - 1 do
    FProps[I].Value.Free;
  inherited;
end;

function TJsonObject.IndexOf(const Name: string): NativeInt;
begin
  for Result := 0 to FCount - 1 do
    if FProps[Result].Name = Name then
      Exit;
  Result := -1;
end;

function TJsonObject.GetValue(const Name: string): TJsonValue;
var
  Index: NativeInt;
begin
  Index := IndexOf(Name);
  if Index < 0 then
    raise EJsonError.CreateFmt('Property "%s" not found', [Name]);
  Result := FProps[Index].Value;
end;

procedure TJsonObject.SetValue(const Name: string; Value: TJsonValue);
var
  Index: NativeInt;
begin
  Value.FContainer := Self;
  Index := IndexOf(Name);
  if Index >= 0 then
  begin
    FProps[Index].Value.Free;
    FProps[Index].Value := Value;
    Exit;
  end;
  if FCount = FCapacity then
  begin
    if FCapacity <= 4 then
      Inc(FCapacity, 4)
    else
      FCapacity := FCapacity * 2;
    SetLength(FProps, FCapacity);
  end;
  FProps[FCount].Name := Name;
  FProps[FCount].Value := Value;
  Inc(FCount);
end;

function TJsonObject.GetProp(Index: NativeInt): TJsonProperty;
begin
  Result := FProps[Index];
end;

{ TJsonArray }

constructor TJsonArray.Create;
begin
  inherited Create(jtArray);
end;

destructor TJsonArray.Destroy;
var
  I: NativeInt;
begin
  for I := 0 to FCount - 1 do
    FItems[I].Free;
  inherited;
end;

procedure TJsonArray.Add(Value: TJsonValue);
begin
  Value.FContainer := Self;
  if FCount = FCapacity then
  begin
    if FCapacity <= 4 then
      Inc(FCapacity, 4)
    else
      FCapacity := FCapacity * 2;
    SetLength(FItems, FCapacity);
  end;
  FItems[FCount] := Value;
  Inc(FCount);
end;

function TJsonArray.GetEnumerator: IJsonEnumerator;
begin
  Result := TJsonArrayEnumerator.Create(FItems, FCount);
end;

function TJsonArray.GetItem(Index: NativeInt): TJsonValue;
begin
  Result := FItems[Index];
end;

{ TJsonArrayEnumerator }

constructor TJsonArrayEnumerator.Create(const Items: TArray<TJsonValue>; Count: NativeInt);
begin
  inherited Create;
  FItems := Items;
  FCount := Count;
  FIndex := -1;
end;

function TJsonArrayEnumerator.GetCurrent: TJsonValue;
begin
  Result := FItems[FIndex];
end;

function TJsonArrayEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FCount;
end;

{ TJsonWriter }

constructor TJsonWriter.Create(const Output: IPacketWriter);
begin
  inherited Create;
  FOutput := Output;
  FTextLength := 256;
  SetLength(FText, FTextLength);
end;

procedure TJsonWriter.Flush;
begin
  FOutput.Write(FStart, NativeUInt(FCurrent - FStart));
  FCurrent := FStart;
end;

procedure TJsonWriter.CheckBuffer(Rest: NativeUInt);
begin
  if NativeUInt(FCurrent - FStart) >= BufferSize - Rest then
    Flush;
end;

procedure TJsonWriter.PutChar(Ch: AnsiChar);
begin
  CheckBuffer(1);
  FCurrent^ := Ch;
  Inc(FCurrent);
end;

// The buffer is flushed first and the bytes written are counted from it, so the loop checks the
// buffer once per character rather than before every write of an escape.
procedure TJsonWriter.PutUtf8(Data: PAnsiChar; Len: Integer);
const
  Hex: array[0..15] of AnsiChar = '0123456789abcdef';
var
  Written: NativeUInt;

  procedure PutEscape(Ch: AnsiChar);
  begin
    FCurrent[0] := '\';
    FCurrent[1] := Ch;
    Inc(FCurrent, 2);
    Inc(Written, 2);
  end;

begin
  Flush;
  Written := 0;
  while Len > 0 do
  begin
    case Data^ of
      #8: PutEscape('b');
      #9: PutEscape('t');
      #10: PutEscape('n');
      #12: PutEscape('f');
      #13: PutEscape('r');
      '"': PutEscape('"');
      '\': PutEscape('\');
      #0..#7, #11, #14..#31:
        begin
          FCurrent[0] := '\';
          FCurrent[1] := 'u';
          FCurrent[2] := '0';
          FCurrent[3] := '0';
          FCurrent[4] := Hex[Ord(Data^) shr 4];
          FCurrent[5] := Hex[Ord(Data^) and $F];
          Inc(FCurrent, 6);
          Inc(Written, 6);
        end;
    else
      FCurrent^ := Data^;
      Inc(FCurrent);
      Inc(Written);
    end;
    Inc(Data);
    Dec(Len);
    if Written >= BufferSize then
    begin
      Flush;
      Written := 0;
    end;
  end;
end;

procedure TJsonWriter.PutString(const Value: string);
var
  L: Integer;
begin
  L := Length(Value);
  if L = 0 then
    Exit;
  L := L * 4 + 1;
  if FTextLength < L then
  begin
    FTextLength := L;
    SetLength(FText, FTextLength);
  end;
  L := UnicodeToUtf8(PAnsiChar(FText), L, PChar(Value), Length(Value));
  if L = 0 then
    raise EJsonError.Create('Invalid UTF-16 text');
  PutUtf8(PAnsiChar(FText), L - 1);
end;

procedure TJsonWriter.Push(Mode: TMode);
begin
  if FDepth >= MaxDepth then
    raise EJsonError.CreateFmt('JSON nesting exceeds %d levels', [MaxDepth]);
  Inc(FDepth);
  FModes[FDepth] := Mode;
  FCounts[FDepth] := 0;
end;

procedure TJsonWriter.Pop;
begin
  if FDepth = 0 then
    raise EJsonError.Create('Unbalanced end of a JSON array or object');
  Dec(FDepth);
end;

procedure TJsonWriter.BeginValue;
begin
  if (FModes[FDepth] = wmArray) and (FCounts[FDepth] > 0) then
    PutChar(',');
  Inc(FCounts[FDepth]);
end;

procedure TJsonWriter.BeginDocument;
begin
  FCurrent := @FBuffer;
  FStart := FCurrent;
  FDepth := 0;
  FModes[0] := wmValue;
  FCounts[0] := 0;
end;

procedure TJsonWriter.EndDocument;
begin
  Flush;
  FOutput.Flush;
end;

procedure TJsonWriter.BeginArray;
begin
  BeginValue;
  PutChar('[');
  Push(wmArray);
end;

procedure TJsonWriter.EndArray;
begin
  Pop;
  PutChar(']');
end;

procedure TJsonWriter.BeginObject;
begin
  BeginValue;
  PutChar('{');
  Push(wmObject);
end;

procedure TJsonWriter.EndObject;
begin
  Pop;
  PutChar('}');
end;

procedure TJsonWriter.WriteKey(const Name: string);
begin
  if FCounts[FDepth] > 0 then
    PutChar(',');
  PutChar('"');
  PutString(Name);
  PutChar('"');
  PutChar(':');
end;

procedure TJsonWriter.WriteText(const Value: string);
begin
  BeginValue;
  PutChar('"');
  PutString(Value);
  PutChar('"');
end;

procedure TJsonWriter.WriteInteger(Value: Int64);
var
  Digits: array[0..19] of AnsiChar;
  N: Integer;
  U: UInt64;
begin
  BeginValue;
  CheckBuffer(21);
  if Value < 0 then
  begin
    FCurrent^ := '-';
    Inc(FCurrent);
    U := UInt64(-(Value + 1)) + 1;
  end
  else
    U := Value;
  N := Length(Digits);
  repeat
    Dec(N);
    Digits[N] := AnsiChar(Ord('0') + U mod 10);
    U := U div 10;
  until U = 0;
  Move(Digits[N], FCurrent^, Length(Digits) - N);
  Inc(FCurrent, Length(Digits) - N);
end;

procedure TJsonWriter.WriteReal(Value: Extended);
var
  Text: array[0..63] of Char;
  N, I: Integer;
begin
  BeginValue;
  CheckBuffer(Length(Text));
  N := FloatToText(PChar(@Text), Value, fvExtended, ffGeneral, 15, 0, JsonFormat);
  for I := 0 to N - 1 do
    FCurrent[I] := AnsiChar(Text[I]);
  Inc(FCurrent, N);
end;

procedure TJsonWriter.WriteBoolean(Value: Boolean);
const
  Words: array[Boolean] of AnsiString = ('false', 'true');
begin
  BeginValue;
  CheckBuffer(5);
  Move(Pointer(Words[Value])^, FCurrent^, Length(Words[Value]));
  Inc(FCurrent, Length(Words[Value]));
end;

procedure TJsonWriter.WriteNull;
begin
  BeginValue;
  CheckBuffer(4);
  Move(PAnsiChar('null')^, FCurrent^, 4);
  Inc(FCurrent, 4);
end;

procedure TJsonWriter.WriteArray(Value: TJsonArray);
var
  I: NativeInt;
begin
  BeginArray;
  for I := 0 to Value.Count - 1 do
    Write(Value[I]);
  EndArray;
end;

procedure TJsonWriter.WriteObject(Value: TJsonObject);
var
  I: NativeInt;
  Prop: TJsonProperty;
begin
  BeginObject;
  for I := 0 to Value.Count - 1 do
  begin
    Prop := Value.Props[I];
    WriteKey(Prop.Name);
    Write(Prop.Value);
  end;
  EndObject;
end;

procedure TJsonWriter.Write(Value: TJsonValue);
begin
  case Value.JsonType of
    jtNull: WriteNull;
    jtBoolean: WriteBoolean(TJsonBoolean(Value).Value);
    jtInteger: WriteInteger(TJsonInteger(Value).Value);
    jtReal: WriteReal(TJsonReal(Value).Value);
    jtString: WriteText(TJsonString(Value).Value);
    jtArray: WriteArray(TJsonArray(Value));
    jtObject: WriteObject(TJsonObject(Value));
  end;
end;

{ TJsonHandler }

constructor TJsonHandler.Create;
begin
  inherited Create;
  FStackCapacity := 8;
  SetLength(FStack, FStackCapacity);
end;

destructor TJsonHandler.Destroy;
begin
  FValue.Free;
  inherited;
end;

procedure TJsonHandler.Push;
begin
  if FStackCount = FStackCapacity then
  begin
    Inc(FStackCapacity, 8);
    SetLength(FStack, FStackCapacity);
  end;
  FStack[FStackCount] := FCurrent;
  Inc(FStackCount);
end;

// A value goes into the property named last, into the current array, or becomes the root
function TJsonHandler.AddValue(Value: TJsonValue): TJsonValue;
begin
  if FIsProperty then
  begin
    TJsonObject(FCurrent)[FPropertyName] := Value;
    FIsProperty := False;
  end
  else if FCurrent is TJsonArray then
    TJsonArray(FCurrent).Add(Value)
  else
    FCurrent := Value;
  if FValue = nil then
    FValue := Value;
  Result := Value;
end;

procedure TJsonHandler.BeginArray;
begin
  if FCurrent <> nil then
    Push;
  FCurrent := AddValue(TJsonArray.Create);
end;

procedure TJsonHandler.EndArray;
begin
  if FStackCount > 0 then
  begin
    Dec(FStackCount);
    FCurrent := FStack[FStackCount];
  end;
end;

procedure TJsonHandler.BeginObject;
begin
  if FCurrent <> nil then
    Push;
  FCurrent := AddValue(TJsonObject.Create);
end;

procedure TJsonHandler.EndObject;
begin
  EndArray;
end;

procedure TJsonHandler.Key(Data: PAnsiChar; Len: Integer);
begin
  DecodeUtf8(Data, Len, FPropertyName);
  FIsProperty := True;
end;

procedure TJsonHandler.Text(Data: PAnsiChar; Len: Integer);
begin
  AddValue(TJsonString.Create(Data, Len));
end;

procedure TJsonHandler.IntegerValue(Value: Int64);
begin
  AddValue(TJsonInteger.Create(Value));
end;

procedure TJsonHandler.RealValue(Value: Extended);
begin
  AddValue(TJsonReal.Create(Value));
end;

procedure TJsonHandler.BooleanValue(Value: Boolean);
begin
  AddValue(TJsonBoolean.Create(Value));
end;

procedure TJsonHandler.NullValue;
begin
  AddValue(TJsonNull.Create);
end;

function TJsonHandler.ExtractValue: TJsonValue;
begin
  Result := FValue;
  FValue := nil;
end;

{ TJsonParser }

constructor TJsonParser.Create;
var
  Ch: AnsiChar;
begin
  inherited Create;
  FTextCapacity := 1024;
  SetLength(FText, FTextCapacity);
  for Ch := Low(AnsiChar) to High(AnsiChar) do
    FSteps[Ch] := Unexpected;
  FSteps['"'] := ParseString;
  FSteps['{'] := ParseObject;
  FSteps['['] := ParseArray;
  FSteps['t'] := ParseTrue;
  FSteps['f'] := ParseFalse;
  FSteps['n'] := ParseNull;
  FSteps['-'] := ParseNumber;
  for Ch := '0' to '9' do
    FSteps[Ch] := ParseNumber;
end;

procedure TJsonParser.Parse(const Input: IPacketReader; const Handler: IJsonHandler);
begin
  FInput := Input;
  FHandler := Handler;
  try
    FEOF := False;
    FBufferSize := FInput.Read(@FBuffer, BufferCapacity);
    if FBufferSize = 0 then
      raise EJsonError.Create('Empty JSON input');
    FPosition := 0;
    FCh := FBuffer[0];
    ParseValue;
    SkipSpace;
    if not FEOF then
      Unexpected;
  finally
    FHandler := nil;
    FInput := nil;
  end;
end;

procedure TJsonParser.Refill;
begin
  FPosition := 0;
  FBufferSize := FInput.Read(@FBuffer, BufferCapacity);
  if FBufferSize = 0 then
  begin
    FBuffer[0] := #0;
    FEOF := True;
  end;
end;

procedure TJsonParser.Next;
begin
  Inc(FPosition);
  if FPosition >= FBufferSize then
    Refill;
  FCh := FBuffer[FPosition];
end;

procedure TJsonParser.SkipSpace;
begin
  while FCh in [' ', #9, #10, #13] do
    Next;
end;

procedure TJsonParser.Expect(Ch: AnsiChar);
begin
  if FCh <> Ch then
    Unexpected;
  Next;
end;

procedure TJsonParser.Unexpected;
begin
  if FEOF then
    raise EJsonError.Create('Unexpected end of JSON input');
  raise EJsonError.CreateFmt('Unexpected character #%d in JSON input', [Ord(FCh)]);
end;

procedure TJsonParser.GrowText;
begin
  FTextCapacity := FTextCapacity * 2;
  SetLength(FText, FTextCapacity);
end;

procedure TJsonParser.PutCodePoint(var Len: NativeUInt; CodePoint: Cardinal);
begin
  if CodePoint < $80 then
    FText[Len] := AnsiChar(CodePoint)
  else if CodePoint < $800 then
  begin
    FText[Len] := AnsiChar($C0 or (CodePoint shr 6));
    Inc(Len);
    FText[Len] := AnsiChar($80 or (CodePoint and $3F));
  end
  else if CodePoint < $10000 then
  begin
    FText[Len] := AnsiChar($E0 or (CodePoint shr 12));
    Inc(Len);
    FText[Len] := AnsiChar($80 or ((CodePoint shr 6) and $3F));
    Inc(Len);
    FText[Len] := AnsiChar($80 or (CodePoint and $3F));
  end
  else
  begin
    FText[Len] := AnsiChar($F0 or (CodePoint shr 18));
    Inc(Len);
    FText[Len] := AnsiChar($80 or ((CodePoint shr 12) and $3F));
    Inc(Len);
    FText[Len] := AnsiChar($80 or ((CodePoint shr 6) and $3F));
    Inc(Len);
    FText[Len] := AnsiChar($80 or (CodePoint and $3F));
  end;
  Inc(Len);
end;

function TJsonParser.ReadHex4: Cardinal;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to 4 do
  begin
    Next;
    case FCh of
      '0'..'9': Result := Result shl 4 + Cardinal(Ord(FCh) - Ord('0'));
      'a'..'f': Result := Result shl 4 + Cardinal(Ord(FCh) - Ord('a') + 10);
      'A'..'F': Result := Result shl 4 + Cardinal(Ord(FCh) - Ord('A') + 10);
    else
      Unexpected;
    end;
  end;
end;

// Every character goes through FText, four bytes of it always free: the longest UTF-8 sequence
// of an escape fits without another check.
function TJsonParser.ScanString: NativeUInt;
var
  CodePoint, Low: Cardinal;
begin
  Result := 0;
  Next;
  while FCh <> '"' do
  begin
    if Result + 4 >= FTextCapacity then
      GrowText;
    if FCh = '\' then
    begin
      Next;
      case FCh of
        '"', '\', '/': FText[Result] := FCh;
        'b': FText[Result] := #8;
        'f': FText[Result] := #12;
        'n': FText[Result] := #10;
        'r': FText[Result] := #13;
        't': FText[Result] := #9;
        'u':
          begin
            CodePoint := ReadHex4;
            if (CodePoint >= $D800) and (CodePoint < $DC00) then
            begin
              Next;
              Expect('\');
              if FCh <> 'u' then
                Unexpected;
              Low := ReadHex4;
              if (Low < $DC00) or (Low >= $E000) then
                raise EJsonError.Create('Invalid surrogate pair in JSON input');
              CodePoint := $10000 + (CodePoint - $D800) shl 10 + (Low - $DC00);
            end;
            PutCodePoint(Result, CodePoint);
            Dec(Result);
          end;
      else
        Unexpected;
      end;
    end
    else if FEOF or (FCh < ' ') then
      Unexpected
    else
      FText[Result] := FCh;
    Inc(Result);
    Next;
  end;
  Next;
end;

procedure TJsonParser.ParseValue;
begin
  SkipSpace;
  FSteps[FCh]();
end;

procedure TJsonParser.ParseObject;
var
  Len: NativeUInt;
begin
  FHandler.BeginObject;
  Next;
  SkipSpace;
  if FCh = '}' then
    Next
  else
    while True do
    begin
      if FCh <> '"' then
        Unexpected;
      Len := ScanString;
      FHandler.Key(PAnsiChar(FText), Len);
      SkipSpace;
      Expect(':');
      ParseValue;
      SkipSpace;
      if FCh = '}' then
      begin
        Next;
        Break;
      end;
      Expect(',');
      SkipSpace;
    end;
  FHandler.EndObject;
end;

procedure TJsonParser.ParseArray;
begin
  FHandler.BeginArray;
  Next;
  SkipSpace;
  if FCh = ']' then
    Next
  else
    while True do
    begin
      ParseValue;
      SkipSpace;
      if FCh = ']' then
      begin
        Next;
        Break;
      end;
      Expect(',');
    end;
  FHandler.EndArray;
end;

procedure TJsonParser.ParseString;
var
  Len: NativeUInt;
begin
  Len := ScanString;
  FHandler.Text(PAnsiChar(FText), Len);
end;

// Up to 18 significant digits go into an Int64 mantissa; a number without a fraction and an
// exponent that fits is an integer
procedure TJsonParser.ParseNumber;
var
  Negative, IsReal, ExpNegative: Boolean;
  Mantissa: Int64;
  Digits, Scale, Exponent: Integer;
  Value: Extended;
begin
  Negative := FCh = '-';
  if Negative then
    Next;
  if not (FCh in ['0'..'9']) then
    Unexpected;
  Mantissa := 0;
  Digits := 0;
  Scale := 0;
  IsReal := False;
  while FCh in ['0'..'9'] do
  begin
    if Digits < 18 then
    begin
      Mantissa := Mantissa * 10 + (Ord(FCh) - Ord('0'));
      Inc(Digits);
    end
    else
      Inc(Scale);
    Next;
  end;
  if FCh = '.' then
  begin
    IsReal := True;
    Next;
    if not (FCh in ['0'..'9']) then
      Unexpected;
    while FCh in ['0'..'9'] do
    begin
      if Digits < 18 then
      begin
        Mantissa := Mantissa * 10 + (Ord(FCh) - Ord('0'));
        Inc(Digits);
        Dec(Scale);
      end;
      Next;
    end;
  end;
  if FCh in ['e', 'E'] then
  begin
    IsReal := True;
    Next;
    ExpNegative := FCh = '-';
    if FCh in ['+', '-'] then
      Next;
    if not (FCh in ['0'..'9']) then
      Unexpected;
    Exponent := 0;
    while FCh in ['0'..'9'] do
    begin
      if Exponent < 100000 then
        Exponent := Exponent * 10 + (Ord(FCh) - Ord('0'));
      Next;
    end;
    if ExpNegative then
      Dec(Scale, Exponent)
    else
      Inc(Scale, Exponent);
  end;
  if not IsReal and (Scale = 0) then
  begin
    if Negative then
      Mantissa := -Mantissa;
    FHandler.IntegerValue(Mantissa);
  end
  else
  begin
    Value := Mantissa;
    if Scale < 0 then
      Value := Value / Power10(-Scale)
    else if Scale > 0 then
      Value := Value * Power10(Scale);
    if Negative then
      Value := -Value;
    FHandler.RealValue(Value);
  end;
end;

procedure TJsonParser.ParseWord(const Word: AnsiString);
var
  I: Integer;
begin
  for I := 1 to Length(Word) do
  begin
    if FCh <> Word[I] then
      Unexpected;
    Next;
  end;
end;

procedure TJsonParser.ParseTrue;
begin
  ParseWord('true');
  FHandler.BooleanValue(True);
end;

procedure TJsonParser.ParseFalse;
begin
  ParseWord('false');
  FHandler.BooleanValue(False);
end;

procedure TJsonParser.ParseNull;
begin
  ParseWord('null');
  FHandler.NullValue;
end;

initialization
  JsonFormat := TFormatSettings.Invariant;

end.
