// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A server that implements the tools API using the [ToolsSupport] mixin.
library;

import 'dart:io' as io;

import 'package:dart_mcp/stdio.dart';
import 'package:mini_mcp_server/mcp_server.dart';

void main() {
  // Create the server and connect it to stdio.
  MCPServerWithTools(stdioChannel(input: io.stdin, output: io.stdout));
}
