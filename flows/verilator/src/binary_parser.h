// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef BINARY_PARSER_H
#define BINARY_PARSER_H

#include <string>

#include "types.h"

class MainMemory;

class BinaryParser {

public:
  // Load the contents of ZBI image and its arguments into `memory`.
  static void load_zbi(const std::string& filename, uint64_t offset, MainMemory& memory);

  // Load the contents of a RISC-V executable and its arguments into `memory`.
  static void load_elf(int argc, char** argv, MainMemory& memory);

  // Load the contents of a binary file into `memory` at `offset`.
  static void load_elf(const std::string& filename, uint64_t offset, MainMemory& memory);

  // Determine the memory address of the first instruction to be executed in the
  // given program.
  static MemoryAddress entry_point(char* filename);

  // Get the memory address to which the named symbol is mapped.
  static MemoryAddress symbol_location(char* filename, std::string symbol);

};

#endif  // BINARY_PARSER_H
