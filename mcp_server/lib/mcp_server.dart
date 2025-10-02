import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';

/// This server uses the [ToolsSupport] mixin to provide tools to the client.
base class MCPServerWithTools extends MCPServer with ToolsSupport {
  MCPServerWithTools(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'An example dart server with tools support',
          version: '0.3.0',
        ),
        instructions: 'Just list, read, create, edit, and call the tools',
      ) {
    registerTool(concatTool, _concat);
    registerTool(listFilesTool, _listFiles);
    registerTool(readFileTool, _readFile);
    registerTool(createFileTool, _createFile);
    registerTool(editFileTool, _editFile);
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
    description: 'returns the contents of a text file specified by path',
    inputSchema: Schema.object(
      properties: {
        'path': Schema.string(description: 'The filesystem path to read from'),
      },
      required: ['path'],
    ),
  );

  /// A tool that creates a new file with content.
  final createFileTool = Tool(
    name: 'createfile',
    description: 'creates a new file at the given path and writes content',
    inputSchema: Schema.object(
      properties: {
        'path': Schema.string(description: 'The path of the file to create'),
        'content': Schema.string(
          description: 'The text to write into the file',
        ),
      },
      required: ['path', 'content'],
    ),
  );

  /// A tool that edits a file by replacing a string with another string.
  final editFileTool = Tool(
    name: 'editfile',
    description:
        'replaces an existing string with a new string in the specified file',
    inputSchema: Schema.object(
      properties: {
        'path': Schema.string(description: 'The path of the file to edit'),
        'oldString': Schema.string(description: 'The string to replace'),
        'newString': Schema.string(
          description: 'The new string to replace with',
        ),
      },
      required: ['path', 'oldString', 'newString'],
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
    return CallToolResult(content: [TextContent(text: fileList.join(" "))]);
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

  /// The implementation of the `createfile` tool.
  Future<CallToolResult> _createFile(CallToolRequest request) async {
    final path = request.arguments!['path'] as String;
    final content = request.arguments!['content'] as String;

    try {
      final file = File(path);
      if (await file.exists()) {
        return CallToolResult(
          content: [
            TextContent(text: 'File already exists at "$path". Overwrite?'),
          ],
        );
      }
      await file.create(recursive: true);
      await file.writeAsString(content);
      return CallToolResult(
        content: [TextContent(text: 'File created at "$path".')],
      );
    } catch (e) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'Error creating file "$path": ${e.runtimeType} - $e',
          ),
        ],
      );
    }
  }

  /// The implementation of the `editfile` tool - replaces existing string with new string.
  Future<CallToolResult> _editFile(CallToolRequest request) async {
    final path = request.arguments!['path'] as String;
    final oldString = request.arguments!['oldString'] as String;
    final newString = request.arguments!['newString'] as String;

    try {
      final file = File(path);
      if (!await file.exists()) {
        return CallToolResult(
          content: [
            TextContent(text: 'File "$path" does not exist. Cannot edit.'),
          ],
        );
      }

      final contents = await file.readAsString();

      // Check if the old string exists
      if (!contents.contains(oldString)) {
        return CallToolResult(
          content: [
            TextContent(text: 'String "$oldString" not found in file "$path".'),
          ],
        );
      }

      // Replace all occurrences
      final newContents = contents.replaceAll(oldString, newString);
      await file.writeAsString(newContents);

      return CallToolResult(
        content: [
          TextContent(
            text: 'Replaced "$oldString" with "$newString" in file "$path".',
          ),
        ],
      );
    } catch (e) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'Error editing file "$path": ${e.runtimeType} - $e',
          ),
        ],
      );
    }
  }
}
