import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sound_stream/sound_stream.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Transcription App',
      theme: ThemeData(primarySwatch: Colors.blue),
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

// --------------------------------------------------
// 1️⃣ HOME PAGE
// --------------------------------------------------
class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _records = [];
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    final dir = await getApplicationDocumentsDirectory();
    final metadataFile = File("${dir.path}/metadata.json");
    if (metadataFile.existsSync()) {
      final data = jsonDecode(metadataFile.readAsStringSync());
      setState(() {
        _records = List<Map<String, dynamic>>.from(data);
      });
      print("📂 Loaded metadata with ${_records.length} records.");
    } else {
      print("ℹ️ No metadata.json file found. Creating new one...");
      metadataFile.writeAsStringSync(jsonEncode([]));
    }
  }

  Future<void> _saveMetadata() async {
    final dir = await getApplicationDocumentsDirectory();
    final metadataFile = File("${dir.path}/metadata.json");
    metadataFile.writeAsStringSync(jsonEncode(_records));
    print("💾 Metadata saved (${_records.length} records).");
  }

  Future<void> _deleteRecording(int index) async {
    final record = _records[index];
    final path = record["path"];
    final file = File(path);

    if (await file.exists()) {
      await file.delete();
      print("🗑️ Deleted file: $path");
    }

    setState(() {
      _records.removeAt(index);
    });
    await _saveMetadata();
  }

  void _playRecording(String path) async {
    try {
      print("▶️ Playing audio file: $path");
      await _player.play(DeviceFileSource(path));
    } catch (e) {
      print("❌ Error playing audio: $e");
    }
  }

  void _goToRecordPage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => RecordPage()),
    );
    _loadMetadata();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Recordings')),
      body: _records.isEmpty
          ? Center(child: Text("No recordings yet"))
          : ListView.builder(
              itemCount: _records.length,
              itemBuilder: (context, index) {
                final record = _records[index];
                return Card(
                  margin: EdgeInsets.all(8),
                  child: ListTile(
                    leading: IconButton(
                      icon: Icon(Icons.play_arrow),
                      onPressed: () => _playRecording(record["path"]),
                    ),
                    title: Text(record["transcription"] ?? "No text"),
                    trailing: IconButton(
                      icon: Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _deleteRecording(index),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _goToRecordPage,
        child: Icon(Icons.add),
      ),
    );
  }
}

// --------------------------------------------------
// 2️⃣ RECORD PAGE (Realtime transcription)
// --------------------------------------------------
class RecordPage extends StatefulWidget {
  @override
  _RecordPageState createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  final RecorderStream _recorder = RecorderStream();
  final AssemblyAIRealtime _assemblyAI = AssemblyAIRealtime();
  final String apiKey = "bc5bee7b4bff42e1a7b87ed6501ed3d5";

  bool _isRecording = false;
  String _transcription = "";
  List<List<int>> _audioChunks = [];

  @override
  void initState() {
    super.initState();
    _setupPermissions();
  }

  Future<void> _setupPermissions() async {
    await Permission.microphone.request();
  }

  Future<void> _startRecording() async {
    print("🎙️ Starting recording...");
    await _assemblyAI.connect(apiKey);

    _recorder.initialize();
    _recorder.start();
    _isRecording = true;

    _recorder.audioStream.listen((data) {
      _assemblyAI.sendAudioChunk(data);
      _audioChunks.add(data);
    });

    _assemblyAI.onTextUpdate = (text) {
      setState(() {
        _transcription = text;
      });
    };

    _assemblyAI.onError = (err) {
      print("❌ AssemblyAI Error: $err");
      setState(() {
        _transcription = "Error: $err";
      });
    };
  }

  Future<void> _stopRecording() async {
    print("🛑 Stopping recording...");
    await _recorder.stop();
    _isRecording = false;
    _assemblyAI.close();
    await _saveRecording();
  }

  Future<void> _saveRecording() async {
    final dir = await getApplicationDocumentsDirectory();
    final id = Uuid().v4();
    final filePath = "${dir.path}/$id.wav";

    final file = File(filePath);
    await file.writeAsBytes(_audioChunks.expand((e) => e).toList());

    final metadataFile = File("${dir.path}/metadata.json");
    List<Map<String, dynamic>> metadata = [];

    if (metadataFile.existsSync()) {
      metadata = List<Map<String, dynamic>>.from(
          jsonDecode(metadataFile.readAsStringSync()));
    }

    metadata.add({
      "id": id,
      "path": filePath,
      "transcription": _transcription,
    });

    metadataFile.writeAsStringSync(jsonEncode(metadata));
    print("💾 Saved new recording to $filePath");
  }

  @override
  void dispose() {
    _assemblyAI.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Live Transcription"),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () {
            _assemblyAI.close();
            Navigator.pop(context);
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _transcription,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),
            SizedBox(height: 20),
            FloatingActionButton(
              backgroundColor: _isRecording ? Colors.red : Colors.green,
              child: Icon(_isRecording ? Icons.stop : Icons.mic),
              onPressed: _isRecording ? _stopRecording : _startRecording,
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------
// 🔧 AssemblyAI Realtime Connection
// --------------------------------------------------
class AssemblyAIRealtime {
  WebSocketChannel? _channel;
  Function(String text)? onTextUpdate;
  Function(String error)? onError;

  Future<void> connect(String apiKey) async {
    final uri = Uri.parse("wss://api.assemblyai.com/v2/realtime/ws?sample_rate=16000");

    try {
      print("🔗 Connecting to AssemblyAI WebSocket...");
      _channel = WebSocketChannel.connect(uri);
      print("✅ Connected! Sending auth...");

      _channel!.sink.add(jsonEncode({
        "auth": apiKey,
        "config": {
          "sample_rate": 16000,
          "encoding": "pcm_s16le"
        }
      }));

      _channel!.stream.listen(
        (message) {
          print("📥 Received: $message");
          final data = jsonDecode(message);

          if (data.containsKey('error')) {
            print("❌ Error: ${data['error']}");
            onError?.call(data['error']);
          } else if (data.containsKey('text')) {
            onTextUpdate?.call(data['text']);
          } else {
            print("⚙️ Other message: $data");
          }
        },
        onError: (err) {
          print("🚨 WebSocket error: $err");
          onError?.call(err.toString());
        },
        onDone: () {
          print("🔚 WebSocket closed");
        },
        cancelOnError: true,
      );
    } catch (e, st) {
      print("💥 Failed to connect: $e");
      print("🧩 StackTrace: $st");
      onError?.call(e.toString());
    }
  }

  void sendAudioChunk(List<int> chunk) {
    try {
      if (_channel != null) {
        print("🎧 Sending ${chunk.length} bytes...");
        _channel!.sink.add(jsonEncode({
          "audio_data": base64Encode(chunk),
        }));
      } else {
        print("⚠️ WebSocket not connected");
      }
    } catch (e) {
      print("🚨 Error sending chunk: $e");
      onError?.call(e.toString());
    }
  }

  void close() {
    try {
      print("🛑 Closing WebSocket...");
      _channel?.sink.close();
    } catch (e) {
      print("⚠️ Error closing: $e");
    }
  }
}
