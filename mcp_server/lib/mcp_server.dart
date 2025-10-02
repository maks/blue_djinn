import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';

/// This server uses the [ToolsSupport] mixin to provide tools to the client.
base class MCPServerWithTools extends MCPServer with ToolsSupport {
  MCPServerWithTools(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'An example dart server with tools support',
          version: '0.1.0',
        ),
        instructions: 'Just list and call the tools',
      ) {
    registerTool(concatTool, _concat);
    registerTool(listFilesTool, _listFiles);
    // Register the new readFile tool
    registerTool(readFileTool, _readFile);
  }

  /// A tool that concatenates a list of strings.
  final concatTool = Tool(
    name: 'concat',
    description: 'concatenates many string parts into one string',
    inputSchema: Schema.object(
      properties: {
        'parts': Schema.list(
          description: 'The parts to concatenate together',
          items: Schema.string(),
        ),
      },
      required: ['parts'],
    ),
  );

  final listFilesTool = Tool(
    name: 'listfiles',
    description:
        'returns a list of file names from the given filesystem path, defaults to current directory if no path is supplied',
    inputSchema: Schema.object(
      properties: {
        'path': Schema.string(
          description: 'The filesystem path to list files from ',
        ),
      },
      required: ['path'],
    ),
  );

  /// A tool that reads the contents of a file.
  final readFileTool = Tool(
    name: 'readfile',
    description:
        'returns the contents of a text file specified by a path relative to the current directory',
    inputSchema: Schema.object(
      properties: {
        'path': Schema.string(
          description: 'The relative filesystem path to read from',
        ),
      },
      required: ['path'],
    ),
  );

  /// The implementation of the `concat` tool.
  FutureOr<CallToolResult> _concat(CallToolRequest request) => CallToolResult(
    content: [
      TextContent(
        text: (request.arguments!['parts'] as List<dynamic>)
            .cast<String>()
            .join(''),
      ),
    ],
  );

  /// The implementation of the `listfiles` tool.
  Future<CallToolResult> _listFiles(CallToolRequest request) async {
    final path = request.arguments?.isNotEmpty ?? false
        ? request.arguments!['path'] as String
        : ".";
    final fileList = [];
    await for (final f in Directory(path).list()) {
      fileList.add(f);
    }
    return CallToolResult(content: [TextContent(text: (fileList.join(" ")))]);
  }

  /// The implementation of the `readfile` tool.
  Future<CallToolResult> _readFile(CallToolRequest request) async {
    final path = request.arguments!['path'] as String;
    try {
      final contents = await File(path).readAsString();
      return CallToolResult(content: [TextContent(text: contents)]);
    } catch (e) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'Error reading file "$path": ${e.runtimeType} - $e',
          ),
        ],
      );
    }
  }
}
