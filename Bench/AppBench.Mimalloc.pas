// AppBench: mimalloc as the RTL memory manager, from mimalloc.dll next to the executable
// Copyright (c) 2026 Alexey Pokroy. MIT License, see LICENSE.
//
// mimalloc.dll is built as a plain DLL, without overriding malloc of the process (MI_OVERRIDE=OFF,
// no mimalloc-redirect.dll); AppBench.ps1 builds it from a release of microsoft/mimalloc. The
// import is static, so the DLL is loaded and initialized before the first unit runs, and it frees
// the heap of an exiting thread itself on DLL_THREAD_DETACH.
//
// The unit comes first in the program: a block the RTL memory manager handed out before it would
// have nobody to free it, so installing over allocated memory stops the program.

unit AppBench.Mimalloc;

interface

// The version of the loaded library: 30600 for 3.6.0
function MimallocVersion: Integer;

implementation

const
  MimallocDll = 'mimalloc.dll';

function mi_malloc(Size: NativeUInt): Pointer; cdecl; external MimallocDll;
function mi_zalloc(Size: NativeUInt): Pointer; cdecl; external MimallocDll;
function mi_realloc(P: Pointer; Size: NativeUInt): Pointer; cdecl; external MimallocDll;
procedure mi_free(P: Pointer); cdecl; external MimallocDll;
function mi_version: Integer; cdecl; external MimallocDll;

function MimallocVersion: Integer;
begin
  Result := mi_version;
end;

function MimallocGetMem(Size: NativeInt): Pointer;
begin
  Result := mi_malloc(Size);
end;

function MimallocFreeMem(P: Pointer): Integer;
begin
  mi_free(P);
  Result := 0;
end;

function MimallocReallocMem(P: Pointer; Size: NativeInt): Pointer;
begin
  Result := mi_realloc(P, Size);
end;

function MimallocAllocMem(Size: NativeInt): Pointer;
begin
  Result := mi_zalloc(Size);
end;

function MimallocRegisterLeak(P: Pointer): Boolean;
begin
  Result := False;
end;

function RtlHasAllocated: Boolean;
var
  State: TMemoryManagerState;
  I: Integer;
begin
  {$WARNINGS OFF}
  GetMemoryManagerState(State);
  {$WARNINGS ON}
  Result := (State.TotalAllocatedMediumBlockSize <> 0) or (State.TotalAllocatedLargeBlockSize <> 0);
  for I := Low(State.SmallBlockTypeStates) to High(State.SmallBlockTypeStates) do
    if State.SmallBlockTypeStates[I].AllocatedBlockCount <> 0 then
      Exit(True);
end;

procedure Install;
var
  Manager: TMemoryManagerEx;
begin
  if IsMemoryManagerSet or RtlHasAllocated then
    Error(reInvalidPtr);
  Manager.GetMem := MimallocGetMem;
  Manager.FreeMem := MimallocFreeMem;
  Manager.ReallocMem := MimallocReallocMem;
  Manager.AllocMem := MimallocAllocMem;
  Manager.RegisterExpectedMemoryLeak := MimallocRegisterLeak;
  Manager.UnregisterExpectedMemoryLeak := MimallocRegisterLeak;
  SetMemoryManager(Manager);
end;

initialization
  Install;

end.
