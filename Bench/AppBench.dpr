// AppBench: application-shaped workloads under different Win64 memory managers
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// One program, built with the RTL memory manager (by default), with ShardMM (-DMM_SHARDMM,
// ..\Source), with mimalloc (-DMM_MIMALLOC, mimalloc.dll next to the executable) or with FastMM5
// (-DMM_FASTMM5, its source on the unit path). The load is not bare GetMem/FreeMem but code as it
// runs in business applications: objects with string and Variant fields in owning lists, binary
// packets written and read through interfaces, a JSON DOM, hash maps, interfaces and closures,
// messages passed between threads. The lists, maps, packets and JSON classes are local units
// (AppBench.*) that reproduce the allocations of a production Delphi code base - instance sizes,
// storage blocks, growth and copies; CheckLayout verifies the instance sizes at start-up.
//
// Scenarios:
//   objects     orders with string fields in owning lists: create, walk, replace at random, free;
//   pack        20 000 rows packed in packets of 100 into a RawByteString and unpacked into new objects;
//   json        an array of 40 objects to UTF-8 text and parsed back, then walked;
//   strings     Format, Split, Trim/UpperCase, Join, StringReplace, TStringList.Sort;
//   maps        string -> Integer and Integer -> object maps of 20 000 keys: insert, look up, delete;
//   interfaces  a list of 500 interface references and a closure per item;
//   pipeline    pairs of threads: one packs messages, the other unpacks and frees them (blocks are
//               freed by another thread than the one that allocated them);
//   mixed       request processing: parse JSON, look up a catalogue map, build an order, pack the
//               response, log to a TStringBuilder;
//   concat      text built by appending: words, an SQL column list with the trailing comma cut off,
//               character by character, a binary packet grown by SetLength and Move (ReallocMem of
//               strings, mostly within the size class of the block);
//   arrays      dynamic arrays grown by one element (SetLength, A := A + [X], an array of records)
//               and then shortened (ReallocMem of dynamic arrays);
//   threads     waves of short-lived threads, each building and freeing 40 orders.
//
// The work per thread is constant, so N threads do N times the work. The time runs up to a barrier
// at which the threads still hold their data, and the memory of the process is taken there too.
// The checksum depends only on the scenario, the thread count and -scale and must be the same for
// every memory manager: a difference means that a manager corrupted memory. A run prints one
// markdown row; AppBench.ps1 builds the variants and compares them.
// Options: -only <scenario> [-threads N] [-scale F] [-header] [-label <text>] [-cores P|E|LPE].
//
// -cores restricts the process to the cores of one class of a hybrid processor (Windows CPU sets):
// P - the highest efficiency class, E - the lowest one on the last-level cache of P, LPE - the
// lowest one on another cache (low-power islands); on a uniform processor all cores are P. Worker N
// is pinned to logical processor N of the set in round robin; the set lists one logical processor
// per physical core first and the second Hyper-Threading siblings after them, so N threads with N
// up to the core count do not share a core. Without the option the scheduler places the threads,
// and on a hybrid processor the same N threads land on P- or E-cores from run to run: the time
// varies by up to a third. The process always opts out of EcoQoS (ProcessPowerThrottling) and runs
// at high priority: otherwise Windows may lower the clock of a background process.

program AppBench;

{$APPTYPE CONSOLE}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

uses
{$IF Defined(MM_MIMALLOC)}
  AppBench.Mimalloc,
{$ELSEIF Defined(MM_SHARDMM)}
  ShardMM,
{$ELSEIF Defined(MM_FASTMM5)}
  FastMM5,
{$IFEND}
  Winapi.Windows,
  Winapi.PsAPI,
  System.SysUtils, System.Classes, System.Variants, System.Diagnostics, System.SyncObjs,
  AppBench.Collections in 'AppBench.Collections.pas',
  AppBench.Packets in 'AppBench.Packets.pas',
  AppBench.Json in 'AppBench.Json.pas';

type
  {$SCOPEDENUMS ON}
  TScenario = (Objects, Pack, Json, Strings, Maps, Interfaces, Pipeline, Mixed, Concat, Arrays, Threads);
  {$SCOPEDENUMS OFF}

const
  ScenarioNames: array[TScenario] of string =
    ('objects', 'pack', 'json', 'strings', 'maps', 'interfaces', 'pipeline', 'mixed', 'concat', 'arrays', 'threads');

  WordCount   = 1024;
  PackRows    = 20000;
  PackBatch   = 100;
  CatalogSize = 2000;
  MapKeys     = 20000;
  RingSize    = 1024;
  LogLimit    = 64 * 1024;

type
  // xorshift64*: every thread has its own generator, Random of the RTL is not thread-safe
  TRng = record
    State: UInt64;
    procedure Seed(Value: UInt64);
    function Next: UInt64; inline;
    function Below(Limit: Cardinal): Integer; inline;
  end;

  TLine = class
  public
    Code: string;
    Name: string;
    Quantity: Integer;
    Price: Currency;
    Note: Variant;
  end;

  TOrder = class
  public
    Id: Int64;
    Client: string;
    Comment: string;
    Created: TDateTime;
    Lines: TOwnedList<TLine>;
    Tags: TValueList<string>;
    constructor Create;
    destructor Destroy; override;
    function Total: Currency;
  end;

  TMessage = class
  public
    Header: string;
    Payload: RawByteString;
    Lines: TOwnedList<TLine>;
    constructor Create;
    destructor Destroy; override;
  end;

  IItem = interface
    ['{6B0C1E57-3F0A-4C55-9C11-2B7F5A4E8D21}']
    function Value: Integer;
    function Name: string;
  end;

  TItem = class(TInterfacedObject, IItem)
  private
    FName: string;
    FValue: Integer;
  public
    constructor Create(const AName: string; AValue: Integer);
    function Value: Integer;
    function Name: string;
  end;

  // A row of the arrays scenario: a record with a managed field, copied by the array growth
  TArrayRow = record
    Id: Int64;
    Name: string;
    Amount: Double;
  end;

  // Single-producer single-consumer queue between the threads of a pipeline pair
  TPipeRing = class
  public
    Items: array[0..RingSize - 1] of TMessage;
    [Volatile] Head: Integer;
    Padding: array[0..14] of Int64;
    [Volatile] Tail: Integer;
    [Volatile] Closed: Boolean;
  end;

  TWorker = class(TThread)
  private
    FScenario: TScenario;
    FIndex: Integer;
    FScale: Double;
    FRng: TRng;
    FRing: TPipeRing;
    FWords: TArray<string>;
    FRows: TOwnedList<TLine>;
    FCatalog: TStrMap<TLine>;
    FCodes: TValueList<string>;
    FLog: TStringBuilder;
    procedure Mix(Value: UInt64); inline;
    procedure MixText(const S: string); inline;
    procedure MakeWords;
    function  NextWord: string; inline;
    function  MakeLine: TLine;
    function  MakeOrder(Id: Int64): TOrder;
    procedure PackLine(const W: IPacketWriter; L: TLine);
    function  UnpackLine(const R: IPacketReader): TLine;
    procedure Work;
    procedure Release;
    procedure RunObjects;
    procedure RunPack;
    procedure RunJson;
    procedure RunStrings;
    procedure RunMaps;
    procedure RunInterfaces;
    procedure RunProducer;
    procedure RunConsumer;
    procedure RunMixed;
    procedure RunConcat;
    procedure RunArrays;
  protected
    procedure Execute; override;
  public
    Ops: Int64;
    Check: UInt64;
    Failure: string;
    constructor Create(AScenario: TScenario; AIndex: Integer; AScale: Double; ARing: TPipeRing; ASuspended: Boolean);
    // The work of one short-lived thread of the threads scenario
    procedure RunWave;
  end;

  TWaveThread = class(TThread)
  private
    FWorker: TWorker;
  protected
    procedure Execute; override;
  public
    constructor Create(AWorker: TWorker);
  end;

var
  StartGate, ReleaseGate: TEvent;
  HoldBarrier: TCountdownEvent;
  // CPU set ids of the chosen core class; empty - the scheduler picks the cores
  CoreSet: TArray<Cardinal>;
  CoreNames: string;

const
  ProcessPowerThrottling = 4;
  PowerThrottlingCurrentVersion = 1;
  PowerThrottlingExecutionSpeed = 1;

type
  TPowerThrottlingState = record
    Version: Cardinal;
    ControlMask: Cardinal;
    StateMask: Cardinal;
  end;

function GetSystemCpuSetInformation(Information: Pointer; BufferLength: Cardinal; out ReturnedLength: Cardinal;
  Process: THandle; Flags: Cardinal): BOOL; stdcall; external kernel32;
function SetProcessDefaultCpuSets(Process: THandle; CpuSetIds: PCardinal; CpuSetIdCount: Cardinal): BOOL; stdcall;
  external kernel32;
function SetThreadSelectedCpuSets(Thread: THandle; CpuSetIds: PCardinal; CpuSetIdCount: Cardinal): BOOL; stdcall;
  external kernel32;
function SetProcessInformation(Process: THandle; InformationClass: Integer; Information: Pointer;
  InformationSize: Cardinal): BOOL; stdcall; external kernel32;

// The process opts out of EcoQoS and runs at high priority; with Name <> '' it is restricted to
// the cores of that class (see the header of the file)
procedure SetupProcess(const Name: string);
type
  // SYSTEM_CPU_SET_INFORMATION, only the fields used
  TCpuSet = record
    Id: Cardinal;
    LogicalIndex: Byte;
    CoreIndex: Byte;
    CacheIndex: Byte;
    Efficiency: Byte;
  end;
var
  Throttling: TPowerThrottlingState;
  Buffer: TBytes;
  Size, Offset: Cardinal;
  Sets, Chosen: TArray<TCpuSet>;
  S: TCpuSet;
  I, J, Pass, Seen: Integer;
  MaxClass, MinClass: Byte;
  PCache: Integer;
  Selected: Boolean;
begin
  Throttling.Version := PowerThrottlingCurrentVersion;
  Throttling.ControlMask := PowerThrottlingExecutionSpeed;
  Throttling.StateMask := 0;
  SetProcessInformation(GetCurrentProcess, ProcessPowerThrottling, @Throttling, SizeOf(Throttling));
  SetPriorityClass(GetCurrentProcess, HIGH_PRIORITY_CLASS);
  if Name = '' then
    Exit;

  Size := 0;
  GetSystemCpuSetInformation(nil, 0, Size, GetCurrentProcess, 0);
  SetLength(Buffer, Size);
  if not GetSystemCpuSetInformation(@Buffer[0], Size, Size, GetCurrentProcess, 0) then
    RaiseLastOSError;
  Offset := 0;
  while Offset < Size do
  begin
    S.Id := PCardinal(@Buffer[Offset + 8])^;
    S.LogicalIndex := Buffer[Offset + 14];
    S.CoreIndex := Buffer[Offset + 15];
    S.CacheIndex := Buffer[Offset + 16];
    S.Efficiency := Buffer[Offset + 18];
    Sets := Sets + [S];
    Inc(Offset, PCardinal(@Buffer[Offset])^);
  end;

  MaxClass := 0;
  MinClass := High(Byte);
  for S in Sets do
  begin
    if S.Efficiency > MaxClass then
      MaxClass := S.Efficiency;
    if S.Efficiency < MinClass then
      MinClass := S.Efficiency;
  end;
  PCache := -1;
  for S in Sets do
    if S.Efficiency = MaxClass then
      PCache := S.CacheIndex;

  for S in Sets do
  begin
    if SameText(Name, 'P') then
      Selected := S.Efficiency = MaxClass
    else if SameText(Name, 'E') then
      Selected := (S.Efficiency = MinClass) and (MinClass < MaxClass) and (S.CacheIndex = PCache)
    else if SameText(Name, 'LPE') then
      Selected := (S.Efficiency = MinClass) and (MinClass < MaxClass) and (S.CacheIndex <> PCache)
    else
      raise Exception.Create('Unknown core class: ' + Name + ' (expected P, E or LPE)');
    if Selected then
      Chosen := Chosen + [S];
  end;
  if Chosen = nil then
    raise Exception.Create('This processor has no cores of class ' + Name);

  // One logical processor per physical core first, then the second Hyper-Threading siblings:
  // workers 0..N-1 with N up to the core count do not share a core
  Pass := 0;
  while Length(CoreSet) < Length(Chosen) do
  begin
    for I := 0 to High(Chosen) do
    begin
      Seen := 0;
      for J := 0 to I - 1 do
        if Chosen[J].CoreIndex = Chosen[I].CoreIndex then
          Inc(Seen);
      if Seen = Pass then
      begin
        CoreSet := CoreSet + [Chosen[I].Id];
        if CoreNames <> '' then
          CoreNames := CoreNames + ',';
        CoreNames := CoreNames + IntToStr(Chosen[I].LogicalIndex);
      end;
    end;
    Inc(Pass);
  end;
  if not SetProcessDefaultCpuSets(GetCurrentProcess, @CoreSet[0], Length(CoreSet)) then
    RaiseLastOSError;
end;

// Thread Index goes to core Index of the set in round robin
procedure PinCurrentThread(Index: Integer);
begin
  if CoreSet <> nil then
    SetThreadSelectedCpuSets(GetCurrentThread, @CoreSet[Index mod Length(CoreSet)], 1);
end;

// The classes standing in for those of the reproduced code base must have their instance sizes:
// the sizes decide the blocks the memory manager sees
procedure CheckLayout;

  procedure Expect(C: TClass; Size: Integer);
  begin
    if C.InstanceSize <> Size then
      raise Exception.CreateFmt('%s: instance size %d, expected %d', [C.ClassName, C.InstanceSize, Size]);
  end;

begin
  Expect(TOwnedList<TLine>, 64);
  Expect(TValueList<string>, 64);
  Expect(TValueList<IItem>, 64);
  Expect(TValueMapCore, 120);
  Expect(TStrIntMap, 120);
  Expect(TStrMap<TLine>, 32);
  Expect(TIntMap<TLine>, 32);
  Expect(TPacketWriter, 120);
  Expect(TPacketReader, 120);
  Expect(TJsonNull, 48);
  Expect(TJsonBoolean, 56);
  Expect(TJsonInteger, 56);
  Expect(TJsonReal, 56);
  Expect(TJsonString, 56);
  Expect(TJsonObject, 96);
  Expect(TJsonArray, 88);
  Expect(TJsonArrayEnumerator, 72);
  Expect(TJsonHandler, 96);
  Expect(TJsonWriter, 213088);
  Expect(TJsonParser, 20576);
end;

{ TRng }

procedure TRng.Seed(Value: UInt64);
begin
  State := Value * $9E3779B97F4A7C15 + $D1B54A32D192ED03;
  if State = 0 then
    State := 1;
end;

function TRng.Next: UInt64;
begin
  State := State xor (State shr 12);
  State := State xor (State shl 25);
  State := State xor (State shr 27);
  Result := State * UInt64($2545F4914F6CDD1D);
end;

function TRng.Below(Limit: Cardinal): Integer;
begin
  Result := Integer(((Next shr 32) * Limit) shr 32);
end;

{ TOrder }

constructor TOrder.Create;
begin
  inherited Create;
  Lines := TOwnedList<TLine>.Create;
  Tags := TValueList<string>.Create;
end;

destructor TOrder.Destroy;
begin
  Tags.Free;
  Lines.Free;
  inherited;
end;

function TOrder.Total: Currency;
var
  L: TLine;
begin
  Result := 0;
  for L in Lines do
    Result := Result + L.Price * L.Quantity;
end;

{ TMessage }

constructor TMessage.Create;
begin
  inherited Create;
  Lines := TOwnedList<TLine>.Create;
end;

destructor TMessage.Destroy;
begin
  Lines.Free;
  inherited;
end;

{ TItem }

constructor TItem.Create(const AName: string; AValue: Integer);
begin
  inherited Create;
  FName := AName;
  FValue := AValue;
end;

function TItem.Value: Integer;
begin
  Result := FValue;
end;

function TItem.Name: string;
begin
  Result := FName;
end;

function MakeAdder(Delta: Integer): TFunc<Int64, Int64>;
begin
  Result :=
    function(Sum: Int64): Int64
    begin
      Result := Sum + Delta;
    end;
end;

{ TWorker }

constructor TWorker.Create(AScenario: TScenario; AIndex: Integer; AScale: Double; ARing: TPipeRing; ASuspended: Boolean);
begin
  FScenario := AScenario;
  FIndex := AIndex;
  FScale := AScale;
  FRing := ARing;
  FRng.Seed(AIndex + 1);
  inherited Create(ASuspended);
end;

procedure TWorker.Mix(Value: UInt64);
begin
  Check := (Check xor Value) * UInt64($100000001B3) + UInt64($9E3779B9);
end;

procedure TWorker.MixText(const S: string);
begin
  if S = '' then
    Mix(0)
  else
    Mix(UInt64(Length(S)) shl 16 + Ord(S[1]));
end;

// Every thread has its own words: strings of a shared dictionary would make the threads share
// reference counts and the cache lines of the strings rather than the memory manager. The
// syllables mix Latin and Cyrillic: a Cyrillic letter takes two bytes in UTF-8, so a decoder that
// sizes its string by the UTF-8 length shrinks it afterwards.
procedure TWorker.MakeWords;
const
  Syllables: array[0..23] of string = ('ка', 'ро', 'ми', 'на', 'сто', 'вер', 'ли', 'жу', 'щен', 'ость',
    'pa', 'lo', 'ri', 'nex', 'tor', 'qua', 'Ба', 'Ост', 'Ин', 'Сер', '-', ' ', '7', '0');
var
  I, J: Integer;
  S: string;
begin
  SetLength(FWords, WordCount);
  for I := 0 to WordCount - 1 do
  begin
    S := '';
    for J := 0 to FRng.Below(9) do
      S := S + Syllables[FRng.Below(Length(Syllables))];
    FWords[I] := S;
  end;
end;

function TWorker.NextWord: string;
begin
  Result := FWords[FRng.Below(WordCount)];
end;

function TWorker.MakeLine: TLine;
begin
  Result := TLine.Create;
  Result.Code := 'A' + IntToStr(FRng.Below(100000));
  Result.Name := NextWord + ' ' + NextWord;
  Result.Quantity := 1 + FRng.Below(50);
  Result.Price := FRng.Below(1000000) / 100;
  case FRng.Below(3) of
    0: Result.Note := Null;
    1: Result.Note := FRng.Below(1000);
  else
    Result.Note := NextWord;
  end;
end;

function TWorker.MakeOrder(Id: Int64): TOrder;
var
  I: Integer;
begin
  Result := TOrder.Create;
  Result.Id := Id;
  Result.Client := NextWord + ' ' + NextWord + ' ' + NextWord;
  if FRng.Below(4) = 0 then
    Result.Comment := 'Order #' + IntToStr(Id) + ' of ' + NextWord;
  Result.Created := 46000 + FRng.Below(1000);
  for I := 0 to FRng.Below(20) do
    Result.Lines.Add(MakeLine);
  for I := 1 to FRng.Below(5) do
    Result.Tags.Add(NextWord);
end;

procedure TWorker.PackLine(const W: IPacketWriter; L: TLine);
begin
  W.WriteInteger(Length(L.Code));
  W.WriteUtf16String(L.Code, Length(L.Code));
  W.WriteInteger(Length(L.Name));
  W.WriteUtf16String(L.Name, Length(L.Name));
  W.WriteInt32(L.Quantity);
  W.WriteDouble(L.Price);
  W.WriteVariant(L.Note);
end;

function TWorker.UnpackLine(const R: IPacketReader): TLine;
begin
  Result := TLine.Create;
  Result.Code := R.ReadUtf16String(NativeUInt(R.ReadInteger));
  Result.Name := R.ReadUtf16String(NativeUInt(R.ReadInteger));
  Result.Quantity := R.ReadInt32;
  Result.Price := R.ReadDouble;
  Result.Note := R.ReadVariant;
end;

procedure TWorker.Execute;
begin
  // The state carrier of the threads scenario is never started; Destroy of such a thread calls
  // Terminate before Resume
  if Terminated then
    Exit;
  PinCurrentThread(FIndex);
  StartGate.WaitFor(INFINITE);
  try
    try
      Work;
    except
      on E: Exception do
        Failure := E.ClassName + ': ' + E.Message;
    end;
  finally
    HoldBarrier.Signal;
  end;
  ReleaseGate.WaitFor(INFINITE);
  Release;
end;

procedure TWorker.Work;
begin
  MakeWords;
  case FScenario of
    TScenario.Objects:    RunObjects;
    TScenario.Pack:       RunPack;
    TScenario.Json:       RunJson;
    TScenario.Strings:    RunStrings;
    TScenario.Maps:       RunMaps;
    TScenario.Interfaces: RunInterfaces;
    TScenario.Pipeline:
      if Odd(FIndex) then
        RunConsumer
      else
        RunProducer;
    TScenario.Mixed:      RunMixed;
    TScenario.Concat:     RunConcat;
    TScenario.Arrays:     RunArrays;
  end;
end;

procedure TWorker.Release;
begin
  FreeAndNil(FRows);
  FreeAndNil(FCatalog);
  FreeAndNil(FCodes);
  FreeAndNil(FLog);
  FWords := nil;
end;

procedure TWorker.RunObjects;
var
  Orders: TOwnedList<TOrder>;
  Order: TOrder;
  Round, I: Integer;
  NextId: Int64;
begin
  NextId := 0;
  for Round := 1 to System.Round(1000 * FScale) do
  begin
    Orders := TOwnedList<TOrder>.Create;
    try
      for I := 1 to 300 do
      begin
        Inc(NextId);
        Orders.Add(MakeOrder(NextId));
      end;
      for Order in Orders do
        Mix(UInt64(Order.Lines.Count) + UInt64(System.Round(Order.Total * 100)));
      for I := 1 to 300 do
      begin
        Orders.Delete(FRng.Below(Orders.Count));
        Inc(NextId);
        Orders.Add(MakeOrder(NextId));
      end;
      for Order in Orders do
      begin
        MixText(Order.Client);
        Mix(Order.Tags.Count);
      end;
      Inc(Ops, 600);
    finally
      Orders.Free;
    end;
  end;
end;

procedure TWorker.RunPack;
var
  Received: TOwnedList<TLine>;
  W: IPacketWriter;
  R: IPacketReader;
  L: TLine;
  Pass, I, J, Count: Integer;
  Packet: RawByteString;
begin
  FRows := TOwnedList<TLine>.Create;
  for I := 1 to PackRows do
    FRows.Add(MakeLine);

  for Pass := 1 to Round(225 * FScale) do
  begin
    Received := TOwnedList<TLine>.Create;
    try
      I := 0;
      while I < FRows.Count do
      begin
        Count := PackBatch;
        if Count > FRows.Count - I then
          Count := FRows.Count - I;
        W := TPacketWriter.Create;
        W.WriteInteger(Count);
        for J := I to I + Count - 1 do
          PackLine(W, FRows[J]);
        W.Flush;
        Packet := W.Data;
        W := nil;

        R := TPacketReader.Create(Packet);
        for J := 1 to R.ReadInteger do
          Received.Add(UnpackLine(R));
        R := nil;
        Mix(Length(Packet));
        Inc(I, Count);
      end;
      for L in Received do
      begin
        MixText(L.Name);
        Mix(L.Quantity);
      end;
      Inc(Ops, 2 * FRows.Count);
    finally
      Received.Free;
    end;
  end;
end;

procedure TWorker.RunJson;
var
  Root, Tags: TJsonArray;
  Obj: TJsonObject;
  Parsed, Value: TJsonValue;
  Text: RawByteString;
  Round, I, J: Integer;
begin
  for Round := 1 to System.Round(9000 * FScale) do
  begin
    Root := TJsonArray.Create;
    try
      for I := 1 to 40 do
      begin
        Obj := TJsonObject.Create;
        Obj['id'] := TJsonInteger.Create(Round * 100 + I);
        Obj['name'] := TJsonString.Create(NextWord + ' ' + NextWord);
        Obj['code'] := TJsonString.Create('A' + IntToStr(FRng.Below(100000)));
        Obj['price'] := TJsonReal.Create(FRng.Below(1000000) / 100);
        Obj['active'] := TJsonBoolean.Create(FRng.Below(2) = 0);
        Tags := TJsonArray.Create;
        for J := 0 to FRng.Below(4) do
          Tags.Add(TJsonString.Create(NextWord));
        Obj['tags'] := Tags;
        Root.Add(Obj);
      end;
      Text := Root.ToUTF8;
    finally
      Root.Free;
    end;

    Parsed := TJsonValue.Load(Text);
    try
      for Value in TJsonArray(Parsed) do
      begin
        Obj := TJsonObject(Value);
        MixText(TJsonString(Obj['name']).Value);
        Mix(TJsonArray(Obj['tags']).Count);
      end;
    finally
      Parsed.Free;
    end;
    Mix(Length(Text));
    Inc(Ops, 2 * 40 * 9);
  end;
end;

procedure TWorker.RunStrings;
var
  Ring: array[0..255] of string;
  List: TStringList;
  Parts: TArray<string>;
  Line, S: string;
  I, J: Integer;
begin
  for I := 1 to Round(1000000 * FScale) do
  begin
    Line := Format('%d;%s;%s;%.2f;%s', [I, NextWord, NextWord, FRng.Below(1000000) / 100, NextWord]);
    Parts := Line.Split([';']);
    for J := 0 to High(Parts) do
      Parts[J] := Trim(UpperCase(Parts[J]));
    S := string.Join(',', Parts);
    S := StringReplace(S, 'КА', 'ka', [rfReplaceAll]);
    Ring[I and High(Ring)] := S + '#' + IntToStr(Length(S));
    if I and High(Ring) = 0 then
    begin
      List := TStringList.Create;
      try
        for J := 0 to High(Ring) do
          List.Add(Ring[J]);
        List.Sort;
        MixText(List[0]);
        Mix(Length(List.Text));
      finally
        List.Free;
      end;
    end;
  end;
  for I := 0 to High(Ring) do
    MixText(Ring[I]);
  Ops := Round(1000000 * FScale);
end;

procedure TWorker.RunMaps;
var
  Map: TStrIntMap;
  Objects: TIntMap<TLine>;
  Keys: TValueList<string>;
  Line: TLine;
  Round, I, Value: Integer;
  Key: string;
begin
  for Round := 1 to System.Round(160 * FScale) do
  begin
    Map := TStrIntMap.Create;
    Objects := TIntMap<TLine>.Create(True);
    Keys := TValueList<string>.Create;
    try
      for I := 0 to MapKeys - 1 do
      begin
        Key := '40702810' + IntToStr(1000000000 + FRng.Below(900000000)) + '00';
        Keys.Add(Key);
        Map.AddOrSetValue(Key, I);
        Line := TLine.Create;
        Line.Code := Key;
        Objects.AddOrSetValue(I, Line);
      end;
      for I := 1 to 2 * MapKeys do
      begin
        if Odd(I) then
          Key := Keys[FRng.Below(Keys.Count)]
        else
          Key := '40702810' + IntToStr(1000000000 + FRng.Below(900000000)) + '00';
        if Map.TryGetValue(Key, Value) then
          Mix(Value);
      end;
      for I := 0 to Keys.Count - 1 do
        if Odd(I) then
        begin
          Map.Remove(Keys[I]);
          Objects.Remove(I);
        end;
      for I := 0 to MapKeys div 2 do
        Map.AddOrSetValue(Keys[I] + 'R', I);
      Mix(Map.Count);
      Mix(Objects.Count);
      Inc(Ops, 5 * MapKeys);
    finally
      Keys.Free;
      Objects.Free;
      Map.Free;
    end;
  end;
end;

procedure TWorker.RunInterfaces;
var
  List: TValueList<IItem>;
  Adder: TFunc<Int64, Int64>;
  Item: IItem;
  Round, I: Integer;
  Sum: Int64;
begin
  for Round := 1 to System.Round(12000 * FScale) do
  begin
    List := TValueList<IItem>.Create;
    try
      for I := 1 to 500 do
        List.Add(TItem.Create(NextWord, I));
      Sum := 0;
      for Item in List do
      begin
        Adder := MakeAdder(Item.Value + Length(Item.Name));
        Sum := Adder(Sum);
      end;
      Adder := nil;
      Mix(Sum);
      Inc(Ops, 1000);
    finally
      List.Free;
    end;
  end;
end;

procedure TWorker.RunProducer;
var
  W: IPacketWriter;
  Msg: TMessage;
  I, J, Next, Count, LineCount: Integer;
  Line: TLine;
begin
  Count := Round(300000 * FScale);
  for I := 1 to Count do
  begin
    Msg := TMessage.Create;
    Msg.Header := 'msg ' + IntToStr(I) + ' ' + NextWord;
    W := TPacketWriter.Create;
    LineCount := 1 + FRng.Below(8);
    W.WriteInteger(LineCount);
    for J := 1 to LineCount do
    begin
      Line := MakeLine;
      try
        PackLine(W, Line);
      finally
        Line.Free;
      end;
    end;
    W.Flush;
    Msg.Payload := W.Data;
    W := nil;
    for J := 0 to FRng.Below(4) do
      Msg.Lines.Add(MakeLine);

    Next := (FRing.Head + 1) and (RingSize - 1);
    while Next = FRing.Tail do
      TThread.Yield;
    FRing.Items[FRing.Head] := Msg;
    FRing.Head := Next;
  end;
  FRing.Closed := True;
  Ops := Count;
end;

procedure TWorker.RunConsumer;
var
  R: IPacketReader;
  Msg: TMessage;
  Unpacked: TOwnedList<TLine>;
  L: TLine;
  J: Integer;
begin
  while True do
  begin
    if FRing.Tail = FRing.Head then
    begin
      if FRing.Closed and (FRing.Tail = FRing.Head) then
        Break;
      TThread.Yield;
      Continue;
    end;
    Msg := FRing.Items[FRing.Tail];
    FRing.Tail := (FRing.Tail + 1) and (RingSize - 1);

    Unpacked := TOwnedList<TLine>.Create;
    try
      R := TPacketReader.Create(Msg.Payload);
      for J := 1 to R.ReadInteger do
        Unpacked.Add(UnpackLine(R));
      R := nil;
      for L in Unpacked do
        MixText(L.Name);
      for L in Msg.Lines do
        Mix(L.Quantity);
      MixText(Msg.Header);
    finally
      Unpacked.Free;
      Msg.Free;
    end;
  end;
end;

procedure TWorker.RunMixed;
var
  Request: TStringBuilder;
  Parsed: TJsonValue;
  Items: TJsonArray;
  Item: TJsonValue;
  Order: TOrder;
  Line, Product: TLine;
  W: IPacketWriter;
  I, J: Integer;
  Code: string;
  Response: RawByteString;
begin
  FCatalog := TStrMap<TLine>.Create(True);
  FCodes := TValueList<string>.Create;
  for I := 1 to CatalogSize do
  begin
    Product := MakeLine;
    if FCatalog.TryAdd(Product.Code, Product) then
      FCodes.Add(Product.Code)
    else
      Product.Free;
  end;
  FLog := TStringBuilder.Create;

  Request := TStringBuilder.Create;
  try
    for I := 1 to Round(200000 * FScale) do
    begin
      Request.Clear;
      Request.Append('{"client":"').Append(NextWord).Append('","id":').Append(I).Append(',"items":[');
      for J := 0 to FRng.Below(10) do
      begin
        if J > 0 then
          Request.Append(',');
        Request.Append('{"code":"').Append(FCodes[FRng.Below(FCodes.Count)]).Append('","qty":')
          .Append(1 + FRng.Below(20)).Append('}');
      end;
      Request.Append(']}');

      Parsed := TJsonValue.Load(UTF8Encode(Request.ToString));
      Order := TOrder.Create;
      try
        Order.Id := I;
        Order.Client := TJsonString(TJsonObject(Parsed)['client']).Value;
        Items := TJsonArray(TJsonObject(Parsed)['items']);
        for Item in Items do
        begin
          Code := TJsonString(TJsonObject(Item)['code']).Value;
          if FCatalog.TryGetValue(Code, Product) then
          begin
            Line := TLine.Create;
            Line.Code := Code;
            Line.Name := Product.Name;
            Line.Price := Product.Price;
            Line.Quantity := TJsonInteger(TJsonObject(Item)['qty']).Value;
            Line.Note := Product.Note;
            Order.Lines.Add(Line);
          end;
        end;

        W := TPacketWriter.Create;
        W.WriteInt64(Order.Id);
        W.WriteInteger(Order.Lines.Count);
        for Line in Order.Lines do
          PackLine(W, Line);
        W.WriteDouble(Order.Total);
        W.Flush;
        Response := W.Data;
        W := nil;

        FLog.Append(Format('%d %s %d %.2f', [Order.Id, Order.Client, Length(Response), Double(Order.Total)])).AppendLine;
        if FLog.Length > LogLimit then
        begin
          Mix(FLog.Length);
          FLog.Clear;
        end;
        Mix(Length(Response));
      finally
        Order.Free;
        Parsed.Free;
      end;
      Inc(Ops);
    end;
  finally
    Request.Free;
  end;
end;

procedure TWorker.RunConcat;
var
  Text, Sql, Chars, Word: string;
  Packet: RawByteString;
  Round, I, J, Len: Integer;
begin
  for Round := 1 to System.Round(300000 * FScale) do
  begin
    // Words appended one by one, as a message or a report line is built
    Text := '';
    for I := 1 to 60 do
      Text := Text + NextWord + ' ';

    // An SQL column list: the trailing comma is cut off, then the rest of the statement follows
    Sql := 'select ';
    for I := 1 to 20 do
      Sql := Sql + 'A.F' + IntToStr(I) + ', ';
    SetLength(Sql, Length(Sql) - 2);
    Sql := Sql + ' from T' + IntToStr(Round mod 50) + ' A where A.ID = ' + IntToStr(Round);

    // Character by character, as a parser or an escaping routine builds its output
    Word := NextWord;
    Chars := '';
    for I := 1 to 4 do
      for J := 1 to Length(Word) do
        Chars := Chars + Word[J];

    // A binary packet grown by SetLength and Move, as a writer without a buffer of its own does
    Packet := '';
    for I := 1 to 40 do
    begin
      Len := Length(Packet);
      SetLength(Packet, Len + SizeOf(Integer) + Length(Word) * SizeOf(Char));
      PInteger(@Packet[Len + 1])^ := I;
      Move(Pointer(Word)^, Packet[Len + 1 + SizeOf(Integer)], Length(Word) * SizeOf(Char));
    end;

    Mix(Length(Text));
    MixText(Sql);
    MixText(Chars);
    Mix(Length(Packet));
    Inc(Ops, 60 + 22 + 4 * Length(Word) + 40);
  end;
end;

procedure TWorker.RunArrays;
var
  Ints: TArray<Integer>;
  Keys: TArray<Int64>;
  Names: TArray<string>;
  Rows: TArray<TArrayRow>;
  Round, I, Sum: Integer;
begin
  for Round := 1 to System.Round(90000 * FScale) do
  begin
    Ints := nil;
    for I := 1 to 300 do
    begin
      SetLength(Ints, Length(Ints) + 1);
      Ints[High(Ints)] := FRng.Below(1000);
    end;

    Keys := nil;
    for I := 1 to 100 do
      Keys := Keys + [Int64(Round) * 1000 + I];

    Names := nil;
    for I := 1 to 50 do
      Names := Names + [NextWord];

    Rows := nil;
    for I := 1 to 50 do
    begin
      SetLength(Rows, Length(Rows) + 1);
      Rows[High(Rows)].Id := I;
      Rows[High(Rows)].Name := Names[I - 1];
      Rows[High(Rows)].Amount := I * 1.5;
    end;

    // A filter keeps part of the elements: the arrays shrink in place
    SetLength(Ints, Length(Ints) div 2);
    SetLength(Rows, Length(Rows) div 3);

    Sum := 0;
    for I := 0 to High(Ints) do
      Inc(Sum, Ints[I]);
    Mix(Sum);
    Mix(Keys[High(Keys)]);
    MixText(Names[High(Names)]);
    MixText(Rows[High(Rows)].Name);
    Inc(Ops, 300 + 100 + 50 + 50);
  end;
end;

procedure TWorker.RunWave;
var
  Orders: TOwnedList<TOrder>;
  Order: TOrder;
  I: Integer;
begin
  MakeWords;
  Orders := TOwnedList<TOrder>.Create;
  try
    for I := 1 to 40 do
      Orders.Add(MakeOrder(I));
    for Order in Orders do
      Mix(UInt64(Round(Order.Total * 100)));
  finally
    Orders.Free;
  end;
  FWords := nil;
end;

{ TWaveThread }

constructor TWaveThread.Create(AWorker: TWorker);
begin
  FWorker := AWorker;
  inherited Create(False);
end;

procedure TWaveThread.Execute;
begin
  PinCurrentThread(FWorker.FIndex);
  FWorker.RunWave;
end;

type
  TResult = record
    Seconds: Double;
    Ops: Int64;
    Check: UInt64;
    HoldMemory, PeakMemory: Int64;
  end;

procedure ReadMemoryUsage(out Current, Peak: Int64);
var
  Counters: TProcessMemoryCounters;
begin
  FillChar(Counters, SizeOf(Counters), 0);
  Counters.cb := SizeOf(Counters);
  GetProcessMemoryInfo(GetCurrentProcess, @Counters, SizeOf(Counters));
  Current := Counters.PagefileUsage;
  Peak := Counters.PeakPagefileUsage;
end;

function RunBarrier(Scenario: TScenario; ThreadCount: Integer; Scale: Double): TResult;
var
  Workers: TArray<TWorker>;
  Rings: TArray<TPipeRing>;
  Watch: TStopwatch;
  I: Integer;
  Unused: Int64;
  Failure: string;
begin
  Result := Default(TResult);
  if Scenario = TScenario.Pipeline then
  begin
    SetLength(Rings, ThreadCount div 2);
    for I := 0 to High(Rings) do
      Rings[I] := TPipeRing.Create;
  end;

  StartGate := TEvent.Create(nil, True, False, '');
  ReleaseGate := TEvent.Create(nil, True, False, '');
  HoldBarrier := TCountdownEvent.Create(ThreadCount);
  try
    SetLength(Workers, ThreadCount);
    for I := 0 to ThreadCount - 1 do
      if Scenario = TScenario.Pipeline then
        Workers[I] := TWorker.Create(Scenario, I, Scale, Rings[I div 2], False)
      else
        Workers[I] := TWorker.Create(Scenario, I, Scale, nil, False);

    Watch := TStopwatch.StartNew;
    StartGate.SetEvent;
    HoldBarrier.WaitFor(INFINITE);
    Result.Seconds := Watch.Elapsed.TotalSeconds;
    ReadMemoryUsage(Result.HoldMemory, Unused);

    ReleaseGate.SetEvent;
    Failure := '';
    for I := 0 to ThreadCount - 1 do
    begin
      Workers[I].WaitFor;
      Inc(Result.Ops, Workers[I].Ops);
      Inc(Result.Check, Workers[I].Check);
      if (Failure = '') and (Workers[I].Failure <> '') then
        Failure := Workers[I].Failure;
      Workers[I].Free;
    end;
  finally
    HoldBarrier.Free;
    ReleaseGate.Free;
    StartGate.Free;
    for I := 0 to High(Rings) do
      Rings[I].Free;
  end;
  if Failure <> '' then
    raise Exception.Create(Failure);
  ReadMemoryUsage(Unused, Result.PeakMemory);
end;

function RunWaves(Width: Integer; Scale: Double): TResult;
var
  Workers: TArray<TWorker>;
  Wave: TArray<TWaveThread>;
  Watch: TStopwatch;
  Waves, W, I: Integer;
  Unused: Int64;
begin
  Result := Default(TResult);
  Waves := Round(4000 * Scale) div Width;
  SetLength(Workers, Width);
  SetLength(Wave, Width);
  for I := 0 to Width - 1 do
    Workers[I] := TWorker.Create(TScenario.Threads, I, Scale, nil, True);
  try
    Watch := TStopwatch.StartNew;
    for W := 1 to Waves do
    begin
      for I := 0 to Width - 1 do
        Wave[I] := TWaveThread.Create(Workers[I]);
      for I := 0 to Width - 1 do
      begin
        Wave[I].WaitFor;
        Wave[I].Free;
      end;
    end;
    Result.Seconds := Watch.Elapsed.TotalSeconds;
    ReadMemoryUsage(Result.HoldMemory, Unused);
    Result.Ops := Int64(Waves) * Width;
    for I := 0 to Width - 1 do
      Inc(Result.Check, Workers[I].Check);
  finally
    for I := 0 to Width - 1 do
      Workers[I].Free;
  end;
  ReadMemoryUsage(Unused, Result.PeakMemory);
end;

function Megabytes(Value: Int64): string;
begin
  Result := FormatFloat('0.0', Value / (1024 * 1024), TFormatSettings.Invariant);
end;

procedure PrintHeader;
begin
  Writeln('| manager | scenario | threads | time, s | k ops/s | memory held, MB | peak, MB | checksum |');
  Writeln('|---|---|---:|---:|---:|---:|---:|---|');
end;

procedure PrintRow(const LabelText: string; Scenario: TScenario; ThreadCount: Integer; const R: TResult);
begin
  Writeln(Format('| %s | %s | %d | %s | %s | %s | %s | %s |', [LabelText, ScenarioNames[Scenario], ThreadCount,
    FormatFloat('0.000', R.Seconds, TFormatSettings.Invariant),
    FormatFloat('0.0', R.Ops / R.Seconds / 1000, TFormatSettings.Invariant),
    Megabytes(R.HoldMemory), Megabytes(R.PeakMemory), IntToHex(R.Check, 16)]));
end;

function DefaultLabel: string;
begin
{$IF Defined(MM_MIMALLOC)}
  Result := 'mimalloc ' + IntToStr(MimallocVersion div 10000) + '.' + IntToStr(MimallocVersion div 100 mod 100) +
    '.' + IntToStr(MimallocVersion mod 100);
{$ELSEIF Defined(MM_SHARDMM)}
  Result := 'ShardMM';
{$ELSEIF Defined(MM_FASTMM5)}
  Result := 'FastMM5';
{$ELSE}
  Result := 'RTL';
{$IFEND}
end;

var
  Only, LabelText, Cores: string;
  ThreadCount, Effective: Integer;
  Scale: Double;
  Header: Boolean;
  Scenario: TScenario;
  Found: Boolean;
  I: Integer;
  R: TResult;
begin
  try
    SetTextCodePage(Output, CP_UTF8);
    SetTextCodePage(ErrOutput, CP_UTF8);
    CheckLayout;
    Only := '';
    Cores := '';
    LabelText := DefaultLabel;
    ThreadCount := 1;
    Scale := 1;
    Header := False;
    I := 1;
    while I <= ParamCount do
    begin
      if SameText(ParamStr(I), '-only') then
      begin
        Inc(I);
        Only := ParamStr(I);
      end
      else if SameText(ParamStr(I), '-threads') then
      begin
        Inc(I);
        ThreadCount := StrToInt(ParamStr(I));
      end
      else if SameText(ParamStr(I), '-scale') then
      begin
        Inc(I);
        Scale := StrToFloat(ParamStr(I), TFormatSettings.Invariant);
      end
      else if SameText(ParamStr(I), '-label') then
      begin
        Inc(I);
        LabelText := ParamStr(I);
      end
      else if SameText(ParamStr(I), '-cores') then
      begin
        Inc(I);
        Cores := ParamStr(I);
      end
      else if SameText(ParamStr(I), '-header') then
        Header := True
      else
        raise Exception.Create('Unknown option: ' + ParamStr(I));
      Inc(I);
    end;

    if Header then
      PrintHeader;
    if (Only = '') and Header then
      Exit;
    SetupProcess(Cores);
    if CoreNames <> '' then
      Writeln(ErrOutput, 'cores ', Cores, ': logical processors ', CoreNames);

    Found := False;
    for Scenario := Low(TScenario) to High(TScenario) do
      if (Only = '') or SameText(Only, ScenarioNames[Scenario]) then
      begin
        Found := True;
        Effective := ThreadCount;
        // Producer-consumer pairs: always an even thread count, at least two
        if Scenario = TScenario.Pipeline then
          Effective := (ThreadCount + 1) and not 1;
        if Scenario = TScenario.Threads then
          R := RunWaves(Effective, Scale)
        else
          R := RunBarrier(Scenario, Effective, Scale);
        PrintRow(LabelText, Scenario, Effective, R);
{$IF Defined(MM_FASTMM5)}
        // How often a thread could not take a FastMM5 arena at once and waited: the FastMM5 README
        // advises to look at these counters before changing the arena count
        if FastMM_SmallBlockThreadContentionCount + FastMM_MediumBlockThreadContentionCount +
          FastMM_LargeBlockThreadContentionCount > 0 then
          Writeln(ErrOutput, Format('FastMM5, %s, %d threads: contention - small blocks %u, medium %u, large %u',
            [ScenarioNames[Scenario], Effective, FastMM_SmallBlockThreadContentionCount,
            FastMM_MediumBlockThreadContentionCount, FastMM_LargeBlockThreadContentionCount]));
{$IFEND}
      end;
    if not Found then
      raise Exception.Create('Unknown scenario: ' + Only);
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
