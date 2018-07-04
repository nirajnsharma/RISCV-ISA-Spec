-- See LICENSE for license details

module MMIO where

-- ================================================================
-- This module handles memory-mapped I/O reads and writes.
-- Fairly trivial I/O for the moment.

-- ================================================================
-- Standard Haskell imports

import Data.Maybe
import Data.Word
import Data.Bits
import Data.Char
import Numeric (showHex, readHex)

-- Project imports

import Arch_Defs
import Mem_Ops

-- ================================================================
-- Memory-mapped IO defs
-- Trivial for now

-- Berkeley ISA tests use htif_console
addr_htif_console_out :: Word64;    addr_htif_console_out = 0xfff4

-- Other programs and tests use a UART for console I/O
addr_base_UART        :: Word64;    addr_base_UART = 10000 -- 0xC0000000
addr_size_UART        :: Word64;    addr_size_UART = 0x80
addr_UART_out         :: Word64;    addr_UART_out  = (addr_base_UART + 0)

-- Real-time counter
addr_mtime            :: Word64;    addr_mtime     = 0x0200BFF8

-- Real-time timer-compare, for timer interrupts
addr_mtimecmp         :: Word64;    addr_mtimecmp  = 0x02004000

-- Generation of software interrupts
addr_msip             :: Word64;    addr_msip      = 0x02000000

-- Supported address ranges (part of the SoC address map)
mmio_addr_ranges :: [ (Word64, Word64) ]
mmio_addr_ranges = [ (addr_htif_console_out,  (addr_htif_console_out + 8)),
                     (addr_base_UART,         (addr_base_UART        + addr_size_UART)),
                     (addr_mtime,             (addr_mtime            + 8)),
                     (addr_mtimecmp,          (addr_mtimecmp         + 8)),
                     (addr_msip,              (addr_msip             + 8))
                   ]

-- Check if the given addr is an I/O addr
is_IO_addr :: Word64 -> Bool
is_IO_addr  addr =
  let
    check :: [(Word64, Word64)] -> Bool
    check  []                  = False
    check  ((base,lim):ranges) = if ((base <= addr) && (addr < lim)) then
                                   True
                                 else
                                   check  ranges
  in
    check  mmio_addr_ranges

-- ================================================================
-- IO subsystem representation
-- This is a private internal representation that can be changed at
-- will; only the exported API can be used by clients.

data MMIO = MMIO {
  -- Real time clock,
  -- real time comparison point, to generate timer interrupts
  f_mtime    :: Word64,
  f_mtimecmp :: Word64,

  -- Location for generating software interrupts
  f_msip :: Word64,

  -- f_console_out_a:  console output that has already been consumed and printed
  -- f_console_out_b:  console output that nas not yet been consumed and printed
  -- f_console_out_a ++ f_console_out_b:  all console output
  f_console_out_a :: String,
  f_console_out_b :: String
  }

mkMMIO :: MMIO
mkMMIO = MMIO { f_console_out_a = [],
                f_console_out_b = [],
                f_mtime         = 1,    -- greater than mtimecmp
                f_mtimecmp      = 0,
                f_msip          = 0
              }

-- ================================================================
-- Read data from MMIO
-- Currently returns a 'ok' with bogus value on most addrs

mmio_read :: MMIO -> InstrField -> Word64 -> (Mem_Result, MMIO)
mmio_read  mmio  funct3  addr =
  if (addr == addr_mtime) then
    let
      mtime = f_mtime  mmio
    in
      (Mem_Result_Ok  mtime,  mmio)

  else if (addr == addr_mtimecmp) then
    let
      mtimecmp = f_mtimecmp  mmio
    in
      (Mem_Result_Ok  mtimecmp,  mmio)

  else if (addr == addr_msip) then
    let
      msip = f_msip  mmio
    in
      (Mem_Result_Ok  msip,  mmio)

  else
    let
      bogus_val = 0xAAAAAAAAAAAAAAAA
    in
      (Mem_Result_Ok  bogus_val, mmio)

-- ================================================================
-- Write data into MMIO

mmio_write :: MMIO -> InstrField -> Word64 -> Word64 -> (Mem_Result, MMIO)
mmio_write  mmio  funct3  addr  val =
  if ((addr == addr_htif_console_out) || (addr == addr_UART_out)) then
    let
      -- Console output
      console_out_b = f_console_out_b  mmio
      char          = chr (fromIntegral val)
      mmio'         = mmio { f_console_out_b = console_out_b ++ [char] }
    in
      (Mem_Result_Ok 0, mmio')

  else if ((addr_base_UART <= addr) && (addr < (addr_base_UART + addr_size_UART))) then
    -- TODO: ignoring other UART writes, for now
    (Mem_Result_Ok 0, mmio)

  else if (addr == addr_mtime) then
    let
      mmio' = mmio { f_mtime = val }
    in
      (Mem_Result_Ok 0, mmio')

  else if (addr == addr_mtimecmp) then
    let
      mmio' = mmio { f_mtimecmp = val }
    in
      (Mem_Result_Ok 0, mmio')

  else if (addr == addr_msip) then
    let
      mmio' = mmio { f_msip = val }
    in
      (Mem_Result_Ok 0, mmio')

  else
    (Mem_Result_Err  exc_code_store_AMO_access_fault, mmio)

-- ================================================================
-- AMO op
-- Currently AMO is not supported on I/O addrs; return access fault.
-- TODO: find out if does LR also return STORE_AMO_ACCESS_FAULT or LOAD_ACCESS_FAULT?

mmio_amo :: MMIO -> Word64 -> InstrField -> InstrField -> InstrField -> InstrField -> Word64 ->
           (Mem_Result, MMIO)

mmio_amo  mmio  addr  funct3  msbs5  aq  rl  val =
  (Mem_Result_Err exc_code_store_AMO_access_fault,  mmio)

-- ================================================================
-- Consume the recorded console-output

mmio_consume_console_output :: MMIO -> (String, MMIO)
mmio_consume_console_output  mmio =
  let
    console_output_a = f_console_out_a  mmio
    console_output_b = f_console_out_b  mmio
    mmio' = mmio { f_console_out_a = console_output_a ++ console_output_b,
                   f_console_out_b = "" }
  in
    (console_output_b, mmio')

-- ================================================================
-- Read all console output

mmio_read_all_console_output :: MMIO -> String
mmio_read_all_console_output  mmio =
  let
    console_output_a = f_console_out_a  mmio
    console_output_b = f_console_out_b  mmio
  in
    console_output_a ++ console_output_b

-- ================================================================
-- Tick mtime and check if timer interrupt

mmio_tick_mtime :: MMIO -> (Bool, MMIO)
mmio_tick_mtime  mmio =
  let
    mtime                  = f_mtime     mmio
    mtimecmp               = f_mtimecmp  mmio
    (interrupt, mtimecmp') = if (mtimecmp >= mtime) then (True, 0)
                             else (False, mtimecmp)
    mmio'        = mmio { f_mtime    = mtime + 1,
                          f_mtimecmp = mtimecmp' }
  in
    (interrupt, mmio')

-- ================================================================
