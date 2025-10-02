import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart' as mcp;
import 'package:dart_mcp/stdio.dart';
import 'package:flutter/material.dart';
import 'package:ollama_dart/ollama_dart.dart';
import 'package:provider/provider.dart';

const MAX_TOOLCALL_ROUNDS = 5;

// --- AppState ChangeNotifier ---
// Manages all state and business logic for the MCP and Ollama clients.
class AppState extends ChangeNotifier {
  // MCP and Process Management
  mcp.MCPClient? _mcpClient;
  mcp.ServerConnection? _serverConnection;
  Process? _serverProcess;
  StreamSubscription? _serverProcessStdoutSub;
  StreamSubscription? _serverProcessStderrSub;

  // Ollama Client
  OllamaClient? _ollamaClient;

  // UI State
  bool _isConnecting = false;
  bool _isConnected = false;
  String _log = '';
  List<mcp.Tool> _availableTools = [];
  ToolCall? _lastToolCall;
  // String modelName = 'llama3.1:8b';
  String modelName = 'qwen3:30b-a3b';

  // Public Getters for UI
  bool get isConnecting => _isConnecting;
  bool get isConnected => _isConnected;
  String get log => _log;
  List<mcp.Tool> get availableTools => _availableTools;
  ToolCall? get lastToolCall => _lastToolCall;

  // --- Core Logic ---

  void _logMessage(String message) {
    _log += '$message\n';
    notifyListeners();
    print(message);
  }

  // Connects to the server process via stdio
  Future<void> connect(String command, String ollamaUrl) async {
    if (_isConnected) {
      await disconnect();
      return;
    }

    _isConnecting = true;
    _log = '';
    _availableTools = [];
    notifyListeners();

    try {
      _logMessage('Starting server process...');
      final cmdSplit = command.split(' ');
      _logMessage('split: $cmdSplit');

      // 1. Start the server as a separate process.
      _serverProcess = await Process.start(cmdSplit[0], cmdSplit.sublist(1));

      // 2. Create the MCP client.
      _mcpClient = mcp.MCPClient(
        mcp.Implementation(name: 'flutter-mcp-client', version: '0.1.0'),
      );

      // 3. Connect the client to the server using the stdio channel.
      _serverConnection = _mcpClient!.connectServer(
        stdioChannel(
          input: _serverProcess!.stdout,
          output: _serverProcess!.stdin,
        ),
      );

      // Listen to stderr for server-side errors
      _serverProcessStderrSub = _serverProcess!.stderr
          .transform(utf8.decoder)
          .listen((data) => _logMessage('[SERVER STDERR]: $data'));

      _logMessage(
        'Process started. PID: ${_serverProcess!.pid}. Initializing MCP...',
      );

      // 4. Initialize the server connection.
      final initializeResult = await _serverConnection!.initialize(
        mcp.InitializeRequest(
          protocolVersion: mcp.ProtocolVersion.latestSupported,
          capabilities: _mcpClient!.capabilities,
          clientInfo: _mcpClient!.implementation,
        ),
      );

      // 5. Notify the server that we are initialized.
      _serverConnection!.notifyInitialized();
      _logMessage(
        '✅ MCP Connection Initialized Successfully: $initializeResult',
      );

      // 6. Initialize Ollama Client
      _ollamaClient = OllamaClient(baseUrl: ollamaUrl);
      _logMessage('✅ Ollama Client Initialized at $ollamaUrl.');

      _isConnected = true;
    } catch (e) {
      _logMessage('❌ ERROR: $e');
      await disconnect(); // Ensure cleanup on failure
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  // Disconnects and cleans up resources
  Future<void> disconnect() async {
    _logMessage('Disconnecting...');
    _isConnected = false;
    _availableTools = [];
    _serverProcessStdoutSub?.cancel();
    _serverProcessStderrSub?.cancel();
    await _mcpClient?.shutdown();
    _serverProcess?.kill();
    _mcpClient = null;
    _serverConnection = null;
    _serverProcess = null;
    _ollamaClient = null;
    _logMessage('Disconnected.');
    notifyListeners();
  }

  // Fetches the list of tools from the connected server
  Future<void> listTools() async {
    if (!_isConnected || _serverConnection == null) {
      _logMessage('Not connected. Cannot list tools.');
      return;
    }
    _logMessage('Requesting list of tools from server...');
    try {
      final toolsResult = await _serverConnection!.listTools(
        mcp.ListToolsRequest(),
      );
      _availableTools = toolsResult.tools;
      _logMessage('✅ Found ${_availableTools.length} tool(s):');
      for (final mcp.Tool tool in _availableTools) {
        _logMessage('  - ${tool.name}: ${tool.description}');
      }
    } catch (e) {
      _logMessage('❌ ERROR listing tools: $e');
    }
    notifyListeners();
  }

  // Calls a specific tool with given arguments
  Future<void> callTool(String toolName, Map<String, dynamic> args) async {
    if (!_isConnected || _serverConnection == null) {
      _logMessage('Not connected. Cannot call tool.');
      return;
    }
    _logMessage('Calling tool `$toolName` with args: $args');
    try {
      final result = await _serverConnection!.callTool(
        mcp.CallToolRequest(name: toolName, arguments: args),
      );
      if (result.isError == false) {
        _logMessage('❌ Tool call failed: ${result.content}');
      } else {
        _logMessage('✅ Tool call success: ${result.content}');
      }
    } catch (e) {
      _logMessage('❌ ERROR calling tool: $e');
    }
    notifyListeners();
  }

  /// Sends a prompt to Ollama, allowing it to use the MCP tools natively.
  /// Supports multiple rounds of tool calls.
  ///
  /// [availableMcpTools] must be a list of `mcp.Tool` objects, for example,
  /// from `_serverConnection.listTools()`.
  Future<void> sendPromptWithNativeToolCalling(
    String prompt,
    List<mcp.Tool> availableMcpTools,
  ) async {
    if (!_isConnected || _ollamaClient == null || _serverConnection == null) {
      _logMessage('Not connected. Cannot process tool-enabled prompt.');
      return;
    }

    _lastToolCall = null;
    notifyListeners();

    _logMessage('\n--- Ollama Query with Native Tool Calling ---');

    // 1. Convert MCP tools to the format Ollama Dart SDK expects.
    final ollamaTools = availableMcpTools.map((mcp.Tool mcpTool) {
      return Tool(
        function: ToolFunction(
          name: mcpTool.name,
          description: mcpTool.description ?? '',
          parameters: mcpTool.inputSchema as Map<String, dynamic>,
        ),
      );
    }).toList();

    _logMessage('Providing ${ollamaTools.length} tool(s) to the LLM.');

    // 2. Initialize the conversation history.
    final messages = [Message(role: MessageRole.user, content: prompt)];

    try {
      // 3. Loop to handle multiple rounds of tool calls.
      for (int i = 0; i < MAX_TOOLCALL_ROUNDS; i++) {
        // Limit to 5 rounds to prevent infinite loops
        final request = GenerateChatCompletionRequest(
          model: modelName,
          messages: messages,
          tools: ollamaTools,
          think: false,
        );

        final res =
            await _ollamaClient!.generateChatCompletion(request: request);
        final messageFromLlm = res.message;
        messages.add(messageFromLlm); // Add LLM's response to history

        // 4. Check if the LLM's response contains tool calls.
        if (messageFromLlm.toolCalls == null ||
            messageFromLlm.toolCalls!.isEmpty) {
          // No more tool calls, this is the final answer.
          _logMessage('🤖 LLM final response:');
          _logMessage(messageFromLlm.content);
          _logMessage('--- End of Ollama Response ---');
          return; // Exit the loop and function.
        }

        // 5. The LLM wants to use one or more tools.
        // The ollama API supports parallel tool calls, so we process all of them.
        final toolCallFutures = messageFromLlm.toolCalls!.map((toolCall) async {
          _lastToolCall = toolCall;
          notifyListeners(); // Update UI to show the latest tool call

          final toolName = toolCall.function?.name;
          final toolArgs = toolCall.function?.arguments;

          _logMessage(
            '💡 LLM wants to call tool: `$toolName` with args: $toolArgs',
          );

          if (toolName == null) {
            return Message(
              role: MessageRole.tool,
              content: jsonEncode({'error': 'Missing tool name from LLM'}),
            );
          }

          // Execute the tool call via MCP.
          try {
            final mcpToolResult = await _serverConnection!.callTool(
              mcp.CallToolRequest(name: toolName, arguments: toolArgs),
            );

            if (mcpToolResult.isError ?? false) {
              _logMessage(
                  '❌ MCP tool execution failed: ${mcpToolResult.content}');
              return Message(
                role: MessageRole.tool,
                content: jsonEncode({'error': mcpToolResult.content}),
              );
            }

            _logMessage(
              '✅ MCP tool executed successfully. Result: ${mcpToolResult.content}',
            );
            return Message(
              role: MessageRole.tool,
              content: jsonEncode(mcpToolResult.content),
            );
          } catch (e) {
            _logMessage('❌ ERROR calling tool `$toolName`: $e');
            return Message(
              role: MessageRole.tool,
              content: jsonEncode({'error': 'Exception during tool call: $e'}),
            );
          }
        });

        // 6. Wait for all tool calls to execute and add their results to the history.
        final toolResults = await Future.wait(toolCallFutures);
        messages.addAll(toolResults);

        _logMessage(
            'Sending ${toolResults.length} tool result(s) back to LLM...');
        // The loop will now continue for the next turn.
      }
      _logMessage('Reached max tool call rounds (5). Ending conversation.');
    } catch (e) {
      _logMessage('❌ ERROR during tool-calling flow: $e');
    } finally {
      notifyListeners();
    }
  }

  // Sends a prompt using **Streaming** to the Ollama API
  // Future<void> sendStreamingPromptToOllama(String prompt) async {
  //   if (!_isConnected || _ollamaClient == null) {
  //     _logMessage('Not connected. Cannot query Ollama.');
  //     return;
  //   }

  //   _logMessage('\n--- Direct Ollama Query ---');
  //   _logMessage('Sending prompt to Ollama: "$prompt"');
  //   try {
  //     final request = GenerateCompletionRequest(
  //       model: modelName,
  //       prompt: prompt,
  //     );

  //     _logMessage('Ollama response:');
  //     var responseBuffer = '';
  //     await for (final res in stream) {
  //       final textChunk = res.response ?? '';
  //       responseBuffer += textChunk;
  //       // Log in chunks to avoid flooding the UI with updates
  //       if (responseBuffer.contains('\n') || responseBuffer.length > 80) {
  //         _logMessage(responseBuffer.trim());
  //         responseBuffer = '';
  //       }
  //     }
  //     // Log any remaining text in the buffer
  //     if (responseBuffer.isNotEmpty) {
  //       _logMessage(responseBuffer.trim());
  //     }
  //     _logMessage('--- End of Ollama Response ---');
  //   } catch (e) {
  //     _logMessage('❌ ERROR querying Ollama: $e');
  //   }
  //   notifyListeners();
  // }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter MCP (stdio) Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

// --- UI Widget ---
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _commandController =
      TextEditingController(text: 'dart run mcp_server/bin/mcp_server.dart');
  final _ollamaUrlController = TextEditingController(
    text: Platform.environment['OLLAMA_BASE_URL'],
  );
  final _logScrollController = ScrollController();
  final _toolArgsController = TextEditingController(text: '{"path": "."}');
  final _ollamaPromptController = TextEditingController();

  @override
  void dispose() {
    _commandController.dispose();
    _ollamaUrlController.dispose();
    _logScrollController.dispose();
    _toolArgsController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_logScrollController.hasClients) {
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final appStateNotifier = context.read<AppState>();

    // Scroll to bottom of logs when they change
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(title: const Text('Flutter MCP (stdio) Client')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left Panel: Controls
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _commandController,
                    decoration: const InputDecoration(
                      labelText: 'Server Command',
                      border: OutlineInputBorder(),
                    ),
                    enabled: !appState.isConnected && !appState.isConnecting,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ollamaUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Ollama URL',
                      border: OutlineInputBorder(),
                    ),
                    enabled: !appState.isConnected && !appState.isConnecting,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: appState.modelName,
                    decoration: const InputDecoration(
                      labelText: 'Ollama Model Name',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      appState.modelName = value;
                    },
                    enabled: !appState.isConnected && !appState.isConnecting,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: appState.isConnecting
                        ? null
                        : () => appState.isConnected
                            ? appStateNotifier.disconnect()
                            : appStateNotifier.connect(
                                _commandController.text,
                                _ollamaUrlController.text,
                              ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: appState.isConnected
                          ? Colors.redAccent
                          : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: appState.isConnecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            appState.isConnected ? 'Disconnect' : 'Connect',
                            style: const TextStyle(fontSize: 16),
                          ),
                  ),
                  const Divider(height: 32),
                  ElevatedButton(
                    onPressed: appState.isConnected
                        ? appStateNotifier.listTools
                        : null,
                    child: const Text('List Available Tools'),
                  ),
                  const SizedBox(height: 16),
                  if (appState.availableTools.isNotEmpty)
                    ..._buildToolButtons(appState, appStateNotifier),
                  _buildToolCallIndicator(appState),
                  const Divider(height: 32),
                  Text(
                    'Direct Ollama Query',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ollamaPromptController,
                    decoration: const InputDecoration(
                      labelText: 'Ollama Prompt',
                      border: OutlineInputBorder(),
                    ),
                    enabled: appState.isConnected,
                    onSubmitted: (value) {
                      if (value.isNotEmpty) {
                        // appStateNotifier.sendStreamingPromptToOllama(value);
                        appStateNotifier.sendPromptWithNativeToolCalling(
                          value,
                          appState.availableTools,
                        );
                        _ollamaPromptController.clear();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: appState.isConnected &&
                            _ollamaPromptController.text.isNotEmpty
                        ? () {
                            // appStateNotifier.sendStreamingPromptToOllama(
                            //   _ollamaPromptController.text,
                            // );
                            appStateNotifier.sendPromptWithNativeToolCalling(
                              _ollamaPromptController.text,
                              appState.availableTools,
                            );
                            _ollamaPromptController.clear();
                          }
                        : null,
                    child: const Text('Send to Ollama'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            // Right Panel: Logs
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade700),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  controller: _logScrollController,
                  // selectable so we can copy/paste out bits of response or logs
                  child: SelectableText(appState.log),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildToolButtons(AppState appState, AppState appStateNotifier) {
    return [
      Text('Call a Tool:', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      TextField(
        controller: _toolArgsController,
        decoration: const InputDecoration(
          labelText: 'Tool Arguments (JSON)',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      ...appState.availableTools.map(
        (tool) => ElevatedButton(
          onPressed: () {
            try {
              final args =
                  jsonDecode(_toolArgsController.text) as Map<String, dynamic>;
              appStateNotifier.callTool(tool.name, args);
            } catch (e) {
              appStateNotifier.callTool(tool.name, {
                'error': 'Invalid JSON: $e',
              });
            }
          },
          child: Text('Call `${tool.name}`'),
        ),
      ),
    ];
  }

  Widget _buildToolCallIndicator(AppState appState) {
    if (appState.lastToolCall == null) {
      return const SizedBox.shrink();
    }

    final toolCall = appState.lastToolCall!;
    final function = toolCall.function;

    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '💡 Tool Call Received',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Divider(),
            ListTile(
              title: Text(function?.name ?? 'Unknown Tool'),
              subtitle: Text(
                'Args: ${function?.arguments.toString() ?? "{}"}',
              ),
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}
