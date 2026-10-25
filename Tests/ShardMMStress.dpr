// ShardMM: multithreaded stress test
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// Every block is filled with a pattern derived from its seed when allocated and checked before it
// is freed, after ReallocMem (the kept part) and after it is handed to another thread: a foreign
// write, the same address handed out twice and data lost on a move all show up as a pattern
// mismatch.
//
// Worker threads keep a ring of blocks and randomly allocate, free, resize and post blocks to the
// mailboxes of other workers, which check and free them. A separate thread keeps starting
// short-lived threads: they allocate, resize, free on their own and post part of their blocks to the
// workers, so a block is freed after the thread that allocated it has exited.
//
// Sizes: 70 % up to 256 bytes, 20 % up to 2 KB, 8 % up to 64 KB, 1.8 % up to 1 MB, 0.2 % up to 4 MB.
// Options: [-threads N] [-seconds S] [-large L] [-medium M]; L - the share of blocks up to 4 MB in
// thousandths (2 by default), taken from the blocks up to 1 MB; M - an extra share of 16 KB - 1 MB
// blocks in thousandths (0 by default). The exit code is the number of errors (0 - passed).
// Built with ShardMM as the first unit; with -DMM_RTL - on the RTL memory manager, to check the test
// itself.

program ShardMMStress;

{$APPTYPE CONSOLE}
{$POINTERMATH ON}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

uses
{$IFNDEF MM_RTL}
  ShardMM,
{$ENDIF}
  Winapi.Windows,
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics;

const
  RingSize = 2048;
  MailLimit = 4096;
  // Blocks up to this size get the whole pattern, larger ones - head, tail and every page
  FullFillLimit = 4096;

var
  // Share of blocks above 1 MB in thousandths; taken from the blocks up to 1 MB
  LargeShare: Cardinal = 2;
  // Extra share of 16 KB - 1 MB blocks in thousandths: with zero the sizes are those without the option
  MediumShare: Cardinal = 0;

type
  TRng = record
    State: UInt64;
    procedure Seed(Value: UInt64);
    function Next: UInt64; inline;
    function Below(Limit: Cardinal): Cardinal; inline;
  end;

  TBlock = record
    P: PByte;
    Size: NativeInt;
    Seed: Cardinal;
  end;

  // Mailbox of a worker: blocks other threads handed to it
  TMailbox = class
  private
    FLock: TRTLCriticalSection;
    FItems: array[0..MailLimit - 1] of TBlock;
    FCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Post(const B: TBlock): Boolean;
    function Take(out Items: TArray<TBlock>): Integer;
  end;

  TStressThread = class(TThread)
  protected
    FRng: TRng;
    procedure Check(const B: TBlock; Limit: NativeInt);
    function  NewBlock: TBlock;
    procedure FreeBlock(var B: TBlock);
    procedure Resize(var B: TBlock);
    procedure SendAway(var B: TBlock);
    procedure DrainMailbox(Mailbox: TMailbox);
  public
    Ops: Int64;
  end;

  TWorker = class(TStressThread)
  private
    FIndex: Integer;
    FRing: array[0..RingSize - 1] of TBlock;
  protected
    procedure Execute; override;
  public
    constructor Create(AIndex: Integer);
  end;

  TShortThread = class(TStressThread)
  protected
    procedure Execute; override;
  public
    constructor Create(ASeed: UInt64);
  end;

  // After the stop checks and frees whatever is left in the mailboxes
  TDrainThread = class(TStressThread)
  protected
    procedure Execute; override;
  public
    constructor Create;
  end;

  TChurnThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Started: Int64;
    ShortOps: Int64;
  end;

var
  Mailboxes: TArray<TMailbox>;
  StopFlag: Integer;
  Errors: Integer;
  FirstError: string;
  ErrorLock: TRTLCriticalSection;

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

function TRng.Below(Limit: Cardinal): Cardinal;
begin
  Result := Cardinal(((Next shr 32) * Limit) shr 32);
end;

procedure ReportError(const Text: string);
begin
  EnterCriticalSection(ErrorLock);
  try
    Inc(Errors);
    if FirstError = '' then
      FirstError := Text;
  finally
    LeaveCriticalSection(ErrorLock);
  end;
end;

function PatternByte(Seed: Cardinal; Offset: NativeInt): Byte; inline;
var
  X: Cardinal;
begin
  X := Seed xor Cardinal(Offset) * $9E3779B1;
  X := X xor (X shr 15);
  Result := Byte(X * $2C1B3C6D shr 24);
end;

procedure FillPattern(P: PByte; Size: NativeInt; Seed: Cardinal; From: NativeInt = 0);
var
  I: NativeInt;
begin
  if Size <= FullFillLimit then
  begin
    for I := From to Size - 1 do
      P[I] := PatternByte(Seed, I);
    Exit;
  end;
  I := From;
  while I < Size do
  begin
    if (I < 64) or (I >= Size - 64) or (I and 4095 < 64) then
      P[I] := PatternByte(Seed, I)
    else if I < Size - 64 then
    begin
      // The middle of a page is skipped: the time goes to the memory manager, not to filling
      I := (I or 4095) + 1;
      if I > Size - 64 then
        I := Size - 64;
      Continue;
    end;
    Inc(I);
  end;
end;

// Checks the bytes up to Limit that FillPattern would have filled in a block of size Size
function CheckPattern(P: PByte; Limit, Size: NativeInt; Seed: Cardinal): NativeInt;
var
  I: NativeInt;
begin
  Result := -1;
  if Size <= FullFillLimit then
  begin
    for I := 0 to Limit - 1 do
      if P[I] <> PatternByte(Seed, I) then
        Exit(I);
    Exit;
  end;
  I := 0;
  while I < Limit do
  begin
    if (I < 64) or (I >= Size - 64) or (I and 4095 < 64) then
    begin
      if P[I] <> PatternByte(Seed, I) then
        Exit(I);
    end
    else if I < Size - 64 then
    begin
      I := (I or 4095) + 1;
      if I > Size - 64 then
        I := Size - 64;
      Continue;
    end;
    Inc(I);
  end;
end;

function RandomSize(var Rng: TRng): NativeInt;
var
  Roll: Cardinal;
begin
  if (MediumShare > 0) and (Rng.Below(1000) < MediumShare) then
    Exit(16385 + NativeInt(Rng.Below(1032191)));
  Roll := Rng.Below(1000);
  if Roll < 700 then
    Result := 1 + NativeInt(Rng.Below(256))
  else if Roll < 900 then
    Result := 257 + NativeInt(Rng.Below(1792))
  else if Roll < 980 then
    Result := 2049 + NativeInt(Rng.Below(63487))
  else if Roll < 1000 - LargeShare then
    Result := 65537 + NativeInt(Rng.Below(983039))
  else
    Result := 1048577 + NativeInt(Rng.Below(3145727));
end;

{ TMailbox }

constructor TMailbox.Create;
begin
  inherited Create;
  InitializeCriticalSection(FLock);
end;

destructor TMailbox.Destroy;
begin
  DeleteCriticalSection(FLock);
  inherited;
end;

function TMailbox.Post(const B: TBlock): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCount < MailLimit;
    if FCount < MailLimit then
    begin
      FItems[FCount] := B;
      Inc(FCount);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMailbox.Take(out Items: TArray<TBlock>): Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCount;
    SetLength(Items, Result);
    if Result > 0 then
      Move(FItems[0], Items[0], Result * SizeOf(TBlock));
    FCount := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ TStressThread }

procedure TStressThread.Check(const B: TBlock; Limit: NativeInt);
var
  Bad: NativeInt;
begin
  Bad := CheckPattern(B.P, Limit, B.Size, B.Seed);
  if Bad >= 0 then
    ReportError(Format('pattern broken: block %p, size %d, offset %d, thread %d',
      [Pointer(B.P), B.Size, Bad, GetCurrentThreadId]));
end;

function TStressThread.NewBlock: TBlock;
begin
  Result.Size := RandomSize(FRng);
  Result.Seed := Cardinal(FRng.Next);
  GetMem(Pointer(Result.P), Result.Size);
  if NativeUInt(Result.P) and 15 <> 0 then
    ReportError(Format('address %p is not 16-byte aligned', [Pointer(Result.P)]));
  FillPattern(Result.P, Result.Size, Result.Seed);
  Inc(Ops);
end;

procedure TStressThread.FreeBlock(var B: TBlock);
begin
  if B.P = nil then
    Exit;
  Check(B, B.Size);
  FreeMem(B.P);
  B.P := nil;
  Inc(Ops);
end;

procedure TStressThread.Resize(var B: TBlock);
var
  NewSize, Kept: NativeInt;
begin
  if FRng.Below(2) = 0 then
    NewSize := RandomSize(FRng)
  else
    NewSize := B.Size + NativeInt(FRng.Below(Cardinal(B.Size) + 64)) - B.Size div 2;
  if NewSize < 1 then
    NewSize := 1;
  ReallocMem(B.P, NewSize);
  Kept := B.Size;
  if Kept > NewSize then
    Kept := NewSize;
  Check(B, Kept);
  // The pattern of the new size is completed with the same seed. The kept part is already filled
  // wherever the new size checks it, except the tail and the case when a large block became small
  // and is now checked as a whole
  if (NewSize <= FullFillLimit) and (B.Size > FullFillLimit) then
    Kept := 0
  else if Kept > NewSize - 64 then
    Kept := NewSize - 64;
  if Kept < 0 then
    Kept := 0;
  B.Size := NewSize;
  FillPattern(B.P, NewSize, B.Seed, Kept);
  Inc(Ops);
end;

procedure TStressThread.SendAway(var B: TBlock);
begin
  if (B.P = nil) or (Length(Mailboxes) = 0) then
    Exit;
  if Mailboxes[FRng.Below(Length(Mailboxes))].Post(B) then
    B.P := nil
  else
    FreeBlock(B);
end;

procedure TStressThread.DrainMailbox(Mailbox: TMailbox);
var
  Items: TArray<TBlock>;
  I: Integer;
begin
  for I := 0 to Mailbox.Take(Items) - 1 do
  begin
    // Every second received block is resized in the new thread first
    if FRng.Below(2) = 0 then
      Resize(Items[I]);
    FreeBlock(Items[I]);
  end;
end;

{ TWorker }

constructor TWorker.Create(AIndex: Integer);
begin
  FIndex := AIndex;
  FRng.Seed(AIndex + 1);
  inherited Create(False);
end;

procedure TWorker.Execute;
var
  Slot: Integer;
  Roll: Cardinal;
  B: TBlock;
begin
  try
    while StopFlag = 0 do
    begin
      Slot := FRng.Below(RingSize);
      Roll := FRng.Below(100);
      // Every fourth thread supplies the one after it: it allocates small blocks and hands them
      // over at once, and the receiver frees them. So the last item in use of a page is freed by a
      // foreign thread while the owner frees the others
      if (FIndex mod 4 = 0) and (FIndex + 1 < Length(Mailboxes)) and (Roll < 60) then
      begin
        B.Size := 1 + NativeInt(FRng.Below(64));
        B.Seed := Cardinal(FRng.Next);
        GetMem(Pointer(B.P), B.Size);
        FillPattern(B.P, B.Size, B.Seed);
        Inc(Ops);
        if not Mailboxes[FIndex + 1].Post(B) then
          FreeBlock(B);
      end
      else if (FIndex mod 4 = 1) and (Roll < 50) then
        DrainMailbox(Mailboxes[FIndex])
      else if Roll < 45 then
      begin
        FreeBlock(FRing[Slot]);
        FRing[Slot] := NewBlock;
      end
      else if Roll < 60 then
        FreeBlock(FRing[Slot])
      else if Roll < 72 then
      begin
        if FRing[Slot].P <> nil then
          Resize(FRing[Slot]);
      end
      else if Roll < 90 then
        SendAway(FRing[Slot])
      else
        DrainMailbox(Mailboxes[FIndex]);
    end;
    for Slot := 0 to RingSize - 1 do
      FreeBlock(FRing[Slot]);
  except
    on E: Exception do
      ReportError('worker: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ TShortThread }

constructor TShortThread.Create(ASeed: UInt64);
begin
  FRng.Seed(ASeed);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TShortThread.Execute;
var
  Local: array[0..63] of TBlock;
  I, Slot: Integer;
begin
  try
    FillChar(Local, SizeOf(Local), 0);
    for I := 1 to 1000 do
    begin
      Slot := FRng.Below(Length(Local));
      case FRng.Below(4) of
        0, 1:
          begin
            FreeBlock(Local[Slot]);
            Local[Slot] := NewBlock;
          end;
        2:
          if Local[Slot].P <> nil then
            Resize(Local[Slot]);
      else
        SendAway(Local[Slot]);
      end;
    end;
    // Half of the remaining blocks outlive their thread and are freed by the workers
    for Slot := 0 to High(Local) do
      if Odd(Slot) then
        SendAway(Local[Slot])
      else
        FreeBlock(Local[Slot]);
  except
    on E: Exception do
      ReportError('short thread: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ TDrainThread }

constructor TDrainThread.Create;
begin
  FRng.Seed(12345);
  inherited Create(False);
end;

procedure TDrainThread.Execute;
var
  Items: TArray<TBlock>;
  I, J: Integer;
begin
  for I := 0 to High(Mailboxes) do
    for J := 0 to Mailboxes[I].Take(Items) - 1 do
      FreeBlock(Items[J]);
end;

{ TChurnThread }

procedure TChurnThread.Execute;
var
  Wave: array[0..3] of TShortThread;
  I: Integer;
begin
  while StopFlag = 0 do
  begin
    for I := 0 to High(Wave) do
    begin
      Inc(Started);
      Wave[I] := TShortThread.Create(UInt64(Started) * 7919);
    end;
    for I := 0 to High(Wave) do
    begin
      Wave[I].WaitFor;
      Inc(ShortOps, Wave[I].Ops);
      Wave[I].Free;
    end;
  end;
end;

var
  ThreadCount, Seconds, I: Integer;
  Workers: TArray<TWorker>;
  Churn: TChurnThread;
  Watch: TStopwatch;
  TotalOps: Int64;
  Drainer: TDrainThread;
begin
  ThreadCount := 16;
  Seconds := 20;
  I := 1;
  while I <= ParamCount do
  begin
    if SameText(ParamStr(I), '-threads') then
    begin
      Inc(I);
      ThreadCount := StrToInt(ParamStr(I));
    end
    else if SameText(ParamStr(I), '-seconds') then
    begin
      Inc(I);
      Seconds := StrToInt(ParamStr(I));
    end
    else if SameText(ParamStr(I), '-large') then
    begin
      Inc(I);
      LargeShare := StrToInt(ParamStr(I));
    end
    else if SameText(ParamStr(I), '-medium') then
    begin
      Inc(I);
      MediumShare := StrToInt(ParamStr(I));
    end;
    Inc(I);
  end;

  InitializeCriticalSection(ErrorLock);
  SetLength(Mailboxes, ThreadCount);
  for I := 0 to ThreadCount - 1 do
    Mailboxes[I] := TMailbox.Create;

  Watch := TStopwatch.StartNew;
  SetLength(Workers, ThreadCount);
  for I := 0 to ThreadCount - 1 do
    Workers[I] := TWorker.Create(I);
  Churn := TChurnThread.Create(False);
  Sleep(Seconds * 1000);
  AtomicExchange(StopFlag, 1);

  TotalOps := 0;
  for I := 0 to ThreadCount - 1 do
  begin
    Workers[I].WaitFor;
    Inc(TotalOps, Workers[I].Ops);
  end;
  Churn.WaitFor;
  Inc(TotalOps, Churn.ShortOps);

  Drainer := TDrainThread.Create;
  Drainer.WaitFor;
  Inc(TotalOps, Drainer.Ops);
  Drainer.Free;

  for I := 0 to ThreadCount - 1 do
  begin
    Workers[I].Free;
    Mailboxes[I].Free;
  end;

  Writeln(Format('threads %d, %d s: operations %d, short threads %d, errors %d',
    [ThreadCount, Seconds, TotalOps, Churn.Started, Errors]));
  if FirstError <> '' then
    Writeln('first error: ', FirstError);
  Churn.Free;
  DeleteCriticalSection(ErrorLock);
  ExitCode := Errors;
end.
