// AppBench: lists and hash maps with the memory layout of a production collection library
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// The benchmark measures memory managers under application code, so these containers reproduce the
// allocations of the code base the workload comes from rather than those of
// System.Generics.Collections: the same instance sizes, the same storage blocks, the same growth.
//
//   TOwnedList<T>, TValueList<T>  the storage is a dynamic array whose length is the capacity: 4,
//                                 then doubled. Delete moves the tail. An owning list being freed
//                                 copies its items into a temporary array and frees the objects
//                                 from the copy.
//   TValueMapCore                 open addressing with linear probing in one block from AllocMem:
//                                 slots [hash 4][key][value], key and value padded to 4 bytes. The
//                                 capacity is a power of two from 4, doubled before an insert into a
//                                 table that is half full; deletion moves the following slots of
//                                 the chain back, without tombstones.
//   TStrIntMap                    string -> Integer, 16-byte slots.
//   TStrMap<V>, TIntMap<V>        a 32-byte object around a map core of string -> object (20-byte
//                                 slots) or Integer -> object (16-byte slots).
//
// String keys hash with XXH32 over their UTF-16 code units, Integer keys by Fibonacci hashing. The
// protected FPadding fields bring every instance to the size of its counterpart; the program checks
// the sizes at start-up.

unit AppBench.Collections;

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

interface

type
  TObjectListCore = class
  private
    FItems: TArray<TObject>;
    FCount: NativeInt;
    FOwnsObjects: Boolean;
    procedure Grow;
  protected
    FPadding: array[0..2] of Pointer;
    function CoreGet(Index: NativeInt): TObject; inline;
    procedure CoreAdd(Value: TObject);
  public
    constructor Create(AOwnsObjects: Boolean);
    destructor Destroy; override;
    procedure Delete(Index: NativeInt);
    procedure Clear;
    property Count: NativeInt read FCount;
  end;

  TOwnedList<T: class> = class(TObjectListCore)
  public type
    TEnumerator = record
    private
      FList: TObjectListCore;
      FIndex: NativeInt;
      function GetCurrent: T; inline;
    public
      function MoveNext: Boolean; inline;
      property Current: T read GetCurrent;
    end;
  private
    function GetItem(Index: NativeInt): T; inline;
  public
    constructor Create(AOwnsObjects: Boolean = True);
    procedure Add(const Value: T); inline;
    function GetEnumerator: TEnumerator; inline;
    property Items[Index: NativeInt]: T read GetItem; default;
  end;

  TValueList<T> = class
  public type
    TEnumerator = record
    private
      FList: TValueList<T>;
      FIndex: NativeInt;
      function GetCurrent: T; inline;
    public
      function MoveNext: Boolean; inline;
      property Current: T read GetCurrent;
    end;
  private
    FItems: TArray<T>;
    FCount: NativeInt;
    function GetItem(Index: NativeInt): T; inline;
    procedure Grow;
  protected
    FPadding: array[0..3] of Pointer;
  public
    procedure Add(const Value: T);
    function GetEnumerator: TEnumerator; inline;
    property Count: NativeInt read FCount;
    property Items[Index: NativeInt]: T read GetItem; default;
  end;

  TMapKeyKind = (mkString, mkInteger);

  TValueMapCore = class
  private const
    EmptyHash = -1;
    KeyOffset = 4;
  private
    FEntries: PByte;
    FCapacity: NativeInt;
    FCount: NativeInt;
    FGrowThreshold: NativeInt;
    FEntrySize: NativeInt;
    FValueOffset: NativeInt;
    FKeyKind: TMapKeyKind;
    function HashOf(Key: Pointer): Integer;
    function Entry(Index: NativeInt): PByte; inline;
    // The slot of the key, or -(the free slot for it) - 1
    function Find(Key: Pointer; Hash: Integer): NativeInt; inline;
    function FindString(const Key: string; Hash: Integer): NativeInt;
    function FindInteger(Key, Hash: Integer): NativeInt;
    procedure Rehash(NewCapacity: NativeInt);
    procedure DeleteAt(Index: NativeInt);
  protected
    FPadding: array[0..5] of Pointer;
    // The address of the value of the key; nil if the key is absent
    function CoreFind(Key: Pointer): PByte;
    // The address of the value to write: a new slot with a zero value or the slot of the key
    function CoreAdd(Key: Pointer; out Added: Boolean): PByte;
    function CoreRemove(Key: Pointer): Boolean;
    // Takes a pointer-sized value out of the map together with its key
    function CoreExtract(Key: Pointer; out Value: Pointer): Boolean;
    // Pointer-sized values in slot order
    function CoreValues: TArray<TObject>;
  public
    constructor Create(AKeyKind: TMapKeyKind; ValueSize: NativeInt);
    destructor Destroy; override;
    procedure Clear;
    property Count: NativeInt read FCount;
  end;

  TStrIntMap = class(TValueMapCore)
  public
    constructor Create;
    procedure AddOrSetValue(const Key: string; Value: Integer); inline;
    function TryGetValue(const Key: string; out Value: Integer): Boolean; inline;
    procedure Remove(const Key: string); inline;
  end;

  TStrMap<V: class> = class
  private
    FMap: TValueMapCore;
    FOwnsValues: Boolean;
  public
    constructor Create(AOwnsValues: Boolean = True);
    destructor Destroy; override;
    procedure Clear;
    function TryAdd(const Key: string; const Value: V): Boolean;
    function TryGetValue(const Key: string; out Value: V): Boolean;
  end;

  TIntMap<V: class> = class
  private
    FMap: TValueMapCore;
    FOwnsValues: Boolean;
    function GetCount: NativeInt; inline;
  public
    constructor Create(AOwnsValues: Boolean = True);
    destructor Destroy; override;
    procedure Clear;
    // A replaced value is freed after the new one is stored, if the map owns its values
    procedure AddOrSetValue(Key: Integer; const Value: V);
    procedure Remove(Key: Integer);
    property Count: NativeInt read GetCount;
  end;

procedure RaiseIndexError(Index: NativeInt);

function XXHash32(Data: PByte; Len: NativeInt; Seed: Cardinal): Cardinal;

implementation

uses
  System.SysUtils;

procedure RaiseIndexError(Index: NativeInt);
begin
  raise EArgumentOutOfRangeException.CreateFmt('List index out of bounds (%d)', [Index]);
end;

function RotL(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shl N) or (X shr (32 - N));
end;

function XXHash32(Data: PByte; Len: NativeInt; Seed: Cardinal): Cardinal;
const
  Prime1 = Cardinal(2654435761);
  Prime2 = Cardinal(2246822519);
  Prime3 = Cardinal(3266489917);
  Prime4 = Cardinal(668265263);
  Prime5 = Cardinal(374761393);
var
  V1, V2, V3, V4: Cardinal;
  Stop: PByte;
begin
  Stop := Data + Len;
  if Len >= 16 then
  begin
    V1 := Seed + Prime1 + Prime2;
    V2 := Seed + Prime2;
    V3 := Seed;
    V4 := Seed - Prime1;
    repeat
      V1 := RotL(V1 + PCardinal(Data)^ * Prime2, 13) * Prime1;
      V2 := RotL(V2 + PCardinal(Data + 4)^ * Prime2, 13) * Prime1;
      V3 := RotL(V3 + PCardinal(Data + 8)^ * Prime2, 13) * Prime1;
      V4 := RotL(V4 + PCardinal(Data + 12)^ * Prime2, 13) * Prime1;
      Inc(Data, 16);
    until Data > Stop - 16;
    Result := RotL(V1, 1) + RotL(V2, 7) + RotL(V3, 12) + RotL(V4, 18);
  end
  else
    Result := Seed + Prime5;
  Inc(Result, Cardinal(Len));
  while Data <= Stop - 4 do
  begin
    Result := RotL(Result + PCardinal(Data)^ * Prime3, 17) * Prime4;
    Inc(Data, 4);
  end;
  while Data < Stop do
  begin
    Result := RotL(Result + Data^ * Prime5, 11) * Prime1;
    Inc(Data);
  end;
  Result := Result xor (Result shr 15);
  Result := Result * Prime2;
  Result := Result xor (Result shr 13);
  Result := Result * Prime3;
  Result := Result xor (Result shr 16);
end;

{ TObjectListCore }

constructor TObjectListCore.Create(AOwnsObjects: Boolean);
begin
  inherited Create;
  FOwnsObjects := AOwnsObjects;
end;

destructor TObjectListCore.Destroy;
begin
  Clear;
  inherited;
end;

procedure TObjectListCore.Grow;
begin
  if FItems = nil then
    SetLength(FItems, 4)
  else
    SetLength(FItems, Length(FItems) * 2);
end;

function TObjectListCore.CoreGet(Index: NativeInt): TObject;
begin
  if NativeUInt(Index) >= NativeUInt(FCount) then
    RaiseIndexError(Index);
  Result := FItems[Index];
end;

procedure TObjectListCore.CoreAdd(Value: TObject);
begin
  if FCount = Length(FItems) then
    Grow;
  FItems[FCount] := Value;
  Inc(FCount);
end;

procedure TObjectListCore.Delete(Index: NativeInt);
var
  Old: TObject;
begin
  if NativeUInt(Index) >= NativeUInt(FCount) then
    RaiseIndexError(Index);
  Old := FItems[Index];
  Dec(FCount);
  if Index < FCount then
    Move(FItems[Index + 1], FItems[Index], (FCount - Index) * SizeOf(TObject));
  FItems[FCount] := nil;
  if FOwnsObjects then
    Old.Free;
end;

// The objects are freed from a copy: a destructor that removes its object from the list finds the
// list already empty.
procedure TObjectListCore.Clear;
var
  Removed: TArray<TObject>;
  I: NativeInt;
begin
  if FCount > 0 then
  begin
    Removed := Copy(FItems, 0, FCount);
    FillChar(FItems[0], FCount * SizeOf(TObject), 0);
    FCount := 0;
    if FOwnsObjects then
      for I := 0 to High(Removed) do
        Removed[I].Free;
  end;
  FItems := nil;
end;

{ TOwnedList<T>.TEnumerator }

function TOwnedList<T>.TEnumerator.GetCurrent: T;
begin
  Result := T(FList.FItems[FIndex]);
end;

function TOwnedList<T>.TEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FList.FCount;
end;

{ TOwnedList<T> }

constructor TOwnedList<T>.Create(AOwnsObjects: Boolean);
begin
  inherited Create(AOwnsObjects);
end;

procedure TOwnedList<T>.Add(const Value: T);
begin
  CoreAdd(Value);
end;

function TOwnedList<T>.GetEnumerator: TEnumerator;
begin
  Result.FList := Self;
  Result.FIndex := -1;
end;

function TOwnedList<T>.GetItem(Index: NativeInt): T;
begin
  Result := T(CoreGet(Index));
end;

{ TValueList<T>.TEnumerator }

function TValueList<T>.TEnumerator.GetCurrent: T;
begin
  Result := FList.FItems[FIndex];
end;

function TValueList<T>.TEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FList.FCount;
end;

{ TValueList<T> }

procedure TValueList<T>.Grow;
begin
  if FItems = nil then
    SetLength(FItems, 4)
  else
    SetLength(FItems, Length(FItems) * 2);
end;

procedure TValueList<T>.Add(const Value: T);
begin
  if FCount = Length(FItems) then
    Grow;
  FItems[FCount] := Value;
  Inc(FCount);
end;

function TValueList<T>.GetEnumerator: TEnumerator;
begin
  Result.FList := Self;
  Result.FIndex := -1;
end;

function TValueList<T>.GetItem(Index: NativeInt): T;
begin
  if NativeUInt(Index) >= NativeUInt(FCount) then
    RaiseIndexError(Index);
  Result := FItems[Index];
end;

{ TValueMapCore }

constructor TValueMapCore.Create(AKeyKind: TMapKeyKind; ValueSize: NativeInt);
begin
  inherited Create;
  FKeyKind := AKeyKind;
  if AKeyKind = mkString then
    FValueOffset := KeyOffset + SizeOf(string)
  else
    FValueOffset := KeyOffset + SizeOf(Integer);
  FEntrySize := FValueOffset + (ValueSize + 3) and not 3;
end;

destructor TValueMapCore.Destroy;
begin
  Clear;
  inherited;
end;

function TValueMapCore.Entry(Index: NativeInt): PByte;
begin
  Result := FEntries + Index * FEntrySize;
end;

function TValueMapCore.HashOf(Key: Pointer): Integer;
const
  Fibonacci = UInt64($9E3779B97F4A7C15);
var
  H: Integer;
  K: UInt64;
begin
  if FKeyKind = mkString then
    H := Integer(XXHash32(PPointer(Key)^, Length(PString(Key)^) * SizeOf(Char), 0))
  else
  begin
    K := UInt64(PCardinal(Key)^) * Fibonacci;
    H := Integer(Cardinal(K) xor Cardinal(K shr 32));
  end;
  // Never negative, so never EmptyHash: the hash of a slot also tells whether the slot is used
  Result := $7FFFFFFF and (($7FFFFFFF and H) + 1);
end;

function TValueMapCore.Find(Key: Pointer; Hash: Integer): NativeInt;
begin
  if FKeyKind = mkString then
    Result := FindString(PString(Key)^, Hash)
  else
    Result := FindInteger(PInteger(Key)^, Hash);
end;

function TValueMapCore.FindString(const Key: string; Hash: Integer): NativeInt;
var
  Mask: NativeInt;
  E: PByte;
begin
  Mask := FCapacity - 1;
  Result := Hash and Mask;
  E := FEntries + Result * FEntrySize;
  while True do
  begin
    if PInteger(E)^ = EmptyHash then
      Exit(-Result - 1);
    if (PInteger(E)^ = Hash) and (PString(E + KeyOffset)^ = Key) then
      Exit;
    Result := (Result + 1) and Mask;
    Inc(E, FEntrySize);
    if Result = 0 then
      E := FEntries;
  end;
end;

function TValueMapCore.FindInteger(Key, Hash: Integer): NativeInt;
var
  Mask: NativeInt;
  E: PByte;
begin
  Mask := FCapacity - 1;
  Result := Hash and Mask;
  E := FEntries + Result * FEntrySize;
  while True do
  begin
    if PInteger(E)^ = EmptyHash then
      Exit(-Result - 1);
    if (PInteger(E)^ = Hash) and (PInteger(E + KeyOffset)^ = Key) then
      Exit;
    Result := (Result + 1) and Mask;
    Inc(E, FEntrySize);
    if Result = 0 then
      E := FEntries;
  end;
end;

// Slots move to the new block as bytes; the old block is freed without finalization, its string
// references now belong to the new one.
procedure TValueMapCore.Rehash(NewCapacity: NativeInt);
var
  Old, E: PByte;
  OldCapacity, I, J, Mask: NativeInt;
begin
  Old := FEntries;
  OldCapacity := FCapacity;
  FEntries := AllocMem(NewCapacity * FEntrySize);
  FCapacity := NewCapacity;
  for I := 0 to NewCapacity - 1 do
    PInteger(Entry(I))^ := EmptyHash;
  FGrowThreshold := NewCapacity shr 1;
  Mask := NewCapacity - 1;
  for I := 0 to OldCapacity - 1 do
  begin
    E := Old + I * FEntrySize;
    if PInteger(E)^ = EmptyHash then
      Continue;
    J := PInteger(E)^ and Mask;
    while PInteger(Entry(J))^ <> EmptyHash do
      J := (J + 1) and Mask;
    Move(E^, Entry(J)^, FEntrySize);
  end;
  FreeMem(Old);
end;

// A slot of the chain behind the freed one moves into the gap unless its home slot lies between
// the gap and the slot itself.
procedure TValueMapCore.DeleteAt(Index: NativeInt);
var
  Mask, Gap, J, Home: NativeInt;
  E: PByte;
  Shift: Boolean;
begin
  if FKeyKind = mkString then
    PString(Entry(Index) + KeyOffset)^ := '';
  Mask := FCapacity - 1;
  Gap := Index;
  J := Index;
  while True do
  begin
    J := (J + 1) and Mask;
    E := Entry(J);
    if PInteger(E)^ = EmptyHash then
      Break;
    Home := PInteger(E)^ and Mask;
    if Gap <= J then
      Shift := (Home <= Gap) or (Home > J)
    else
      Shift := (Home <= Gap) and (Home > J);
    if Shift then
    begin
      Move(E^, Entry(Gap)^, FEntrySize);
      Gap := J;
    end;
  end;
  E := Entry(Gap);
  FillChar(E^, FEntrySize, 0);
  PInteger(E)^ := EmptyHash;
  Dec(FCount);
end;

function TValueMapCore.CoreFind(Key: Pointer): PByte;
var
  I: NativeInt;
begin
  if FCount = 0 then
    Exit(nil);
  I := Find(Key, HashOf(Key));
  if I < 0 then
    Result := nil
  else
    Result := Entry(I) + FValueOffset;
end;

// The table grows only before a new key goes in.
function TValueMapCore.CoreAdd(Key: Pointer; out Added: Boolean): PByte;
var
  Hash: Integer;
  I: NativeInt;
  E: PByte;
begin
  Hash := HashOf(Key);
  if FCapacity = 0 then
    I := -1
  else
    I := Find(Key, Hash);
  Added := I < 0;
  if Added then
  begin
    if FCount >= FGrowThreshold then
    begin
      if FCapacity = 0 then
        Rehash(4)
      else
        Rehash(FCapacity * 2);
      I := Find(Key, Hash);
    end;
    E := Entry(-I - 1);
    PInteger(E)^ := Hash;
    if FKeyKind = mkString then
      PString(E + KeyOffset)^ := PString(Key)^
    else
      PInteger(E + KeyOffset)^ := PInteger(Key)^;
    Inc(FCount);
  end
  else
    E := Entry(I);
  Result := E + FValueOffset;
end;

function TValueMapCore.CoreRemove(Key: Pointer): Boolean;
var
  I: NativeInt;
begin
  if FCount = 0 then
    Exit(False);
  I := Find(Key, HashOf(Key));
  Result := I >= 0;
  if Result then
    DeleteAt(I);
end;

function TValueMapCore.CoreExtract(Key: Pointer; out Value: Pointer): Boolean;
var
  I: NativeInt;
begin
  Value := nil;
  if FCount = 0 then
    Exit(False);
  I := Find(Key, HashOf(Key));
  Result := I >= 0;
  if Result then
  begin
    Value := PPointer(Entry(I) + FValueOffset)^;
    DeleteAt(I);
  end;
end;

function TValueMapCore.CoreValues: TArray<TObject>;
var
  I, N: NativeInt;
begin
  SetLength(Result, FCount);
  N := 0;
  for I := 0 to FCapacity - 1 do
    if PInteger(Entry(I))^ <> EmptyHash then
    begin
      Result[N] := TObject(PPointer(Entry(I) + FValueOffset)^);
      Inc(N);
    end;
end;

procedure TValueMapCore.Clear;
var
  I: NativeInt;
begin
  if FKeyKind = mkString then
    for I := 0 to FCapacity - 1 do
      if PInteger(Entry(I))^ <> EmptyHash then
        PString(Entry(I) + KeyOffset)^ := '';
  FreeMem(FEntries);
  FEntries := nil;
  FCapacity := 0;
  FCount := 0;
  FGrowThreshold := 0;
end;

{ TStrIntMap }

constructor TStrIntMap.Create;
begin
  inherited Create(mkString, SizeOf(Integer));
end;

procedure TStrIntMap.AddOrSetValue(const Key: string; Value: Integer);
var
  Added: Boolean;
begin
  PInteger(CoreAdd(@Key, Added))^ := Value;
end;

function TStrIntMap.TryGetValue(const Key: string; out Value: Integer): Boolean;
var
  P: PByte;
begin
  P := CoreFind(@Key);
  Result := P <> nil;
  if Result then
    Value := PInteger(P)^
  else
    Value := 0;
end;

procedure TStrIntMap.Remove(const Key: string);
begin
  CoreRemove(@Key);
end;

{ TStrMap<V> }

constructor TStrMap<V>.Create(AOwnsValues: Boolean);
begin
  inherited Create;
  FMap := TValueMapCore.Create(mkString, SizeOf(Pointer));
  FOwnsValues := AOwnsValues;
end;

destructor TStrMap<V>.Destroy;
begin
  if FMap <> nil then
    Clear;
  FMap.Free;
  inherited;
end;

// The table empties first, then the values go: a destructor that removes its value from the map
// finds nothing
procedure TStrMap<V>.Clear;
var
  Values: TArray<TObject>;
  I: NativeInt;
begin
  if FOwnsValues then
  begin
    Values := FMap.CoreValues;
    FMap.Clear;
    for I := 0 to High(Values) do
      Values[I].Free;
  end
  else
    FMap.Clear;
end;

function TStrMap<V>.TryAdd(const Key: string; const Value: V): Boolean;
var
  P: PByte;
begin
  P := FMap.CoreAdd(@Key, Result);
  if Result then
    PPointer(P)^ := Pointer(Value);
end;

function TStrMap<V>.TryGetValue(const Key: string; out Value: V): Boolean;
var
  P: PByte;
begin
  P := FMap.CoreFind(@Key);
  Result := P <> nil;
  if Result then
    Value := V(PPointer(P)^)
  else
    Value := nil;
end;

{ TIntMap<V> }

constructor TIntMap<V>.Create(AOwnsValues: Boolean);
begin
  inherited Create;
  FMap := TValueMapCore.Create(mkInteger, SizeOf(Pointer));
  FOwnsValues := AOwnsValues;
end;

destructor TIntMap<V>.Destroy;
begin
  if FMap <> nil then
    Clear;
  FMap.Free;
  inherited;
end;

procedure TIntMap<V>.Clear;
var
  Values: TArray<TObject>;
  I: NativeInt;
begin
  if FOwnsValues then
  begin
    Values := FMap.CoreValues;
    FMap.Clear;
    for I := 0 to High(Values) do
      Values[I].Free;
  end
  else
    FMap.Clear;
end;

function TIntMap<V>.GetCount: NativeInt;
begin
  Result := FMap.Count;
end;

procedure TIntMap<V>.AddOrSetValue(Key: Integer; const Value: V);
var
  Added: Boolean;
  P: PByte;
  Old: TObject;
begin
  P := FMap.CoreAdd(@Key, Added);
  if Added then
    Old := nil
  else
    Old := TObject(PPointer(P)^);
  PPointer(P)^ := Pointer(Value);
  if FOwnsValues and (Old <> TObject(Value)) then
    Old.Free;
end;

procedure TIntMap<V>.Remove(Key: Integer);
var
  Value: Pointer;
begin
  if FMap.CoreExtract(@Key, Value) and FOwnsValues then
    TObject(Value).Free;
end;

end.
