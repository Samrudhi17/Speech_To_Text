import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Speech to Text App",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigoAccent),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontFamily: 'Roboto'),
        ),
      ),
      home: const AudioListPage(),
    );
  }
}

/// -------------------------------
/// PAGE 1: AUDIO LIST PAGE
/// -------------------------------
class AudioListPage extends StatefulWidget {
  const AudioListPage({super.key});

  @override
  State<AudioListPage> createState() => _AudioListPageState();
}

class _AudioListPageState extends State<AudioListPage> {
  List<Map<String, dynamic>> _audioList = [];
  FlutterSoundPlayer? _player;

  @override
  void initState() {
    super.initState();
    _loadAudioList();
    _player = FlutterSoundPlayer();
    _player!.openPlayer();
  }

  Future<void> _loadAudioList() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('audio_list');
    if (data != null) {
      setState(() {
        _audioList = List<Map<String, dynamic>>.from(jsonDecode(data));
      });
    }
  }

  Future<void> _playAudio(String filePath) async {
    await _player!.startPlayer(fromURI: filePath);
  }

  Future<void> _stopAudio() async {
    await _player!.stopPlayer();
  }

  @override
  void dispose() {
    _player?.closePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.indigoAccent,
        elevation: 4,
        title: const Text(
          "My Recordings",
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
      ),
      body: _audioList.isEmpty
          ? const Center(
              child: Text(
                "No recordings yet.\nTap '+' to record new audio.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _audioList.length,
              itemBuilder: (context, index) {
                final item = _audioList[index];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black12.withOpacity(0.1),
                        blurRadius: 6,
                        offset: const Offset(2, 4),
                      ),
                    ],
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    title: Text(
                      "Recording ${index + 1}",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        color: Colors.indigoAccent,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        item['text'] ?? 'No transcription available',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    trailing: CircleAvatar(
                      radius: 22,
                      backgroundColor: Colors.indigoAccent.withOpacity(0.15),
                      child: IconButton(
                        icon: const Icon(Icons.play_circle_fill,
                            color: Colors.indigoAccent, size: 30),
                        onPressed: () => _playAudio(item['path']),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.indigoAccent,
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SpeakToTextPage()),
          );
          _loadAudioList();
        },
        icon: const Icon(Icons.mic, color: Colors.white),
        label: const Text(
          "Record",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// -------------------------------
/// PAGE 2: LIVE RECORDING + TRANSCRIBE
/// -------------------------------
class SpeakToTextPage extends StatefulWidget {
  const SpeakToTextPage({super.key});

  @override
  State<SpeakToTextPage> createState() => _SpeakToTextPageState();
}

class _SpeakToTextPageState extends State<SpeakToTextPage> {
  FlutterSoundRecorder? _recorder;
  bool isRecording = false;
  String _transcription = "";
  bool _isLoading = false;
  IOWebSocketChannel? _channel;

  Future<void> _saveRecording(String path, String text) async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('audio_list');
    List<Map<String, dynamic>> list = [];
    if (data != null) {
      list = List<Map<String, dynamic>>.from(jsonDecode(data));
    }
    list.add({'path': path, 'text': text});
    await prefs.setString('audio_list', jsonEncode(list));
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      throw Exception('Microphone permission not granted');
    }

    const String apiKey = 'bc5bee7b4bff42e1a7b87ed6501ed3d5';
    const String realtimeUrl =
        'wss://api.assemblyai.com/v2/realtime/ws?sample_rate=16000';

    setState(() {
      isRecording = true;
      _transcription = "";
    });

    // Connect to AssemblyAI Realtime API
    _channel = IOWebSocketChannel.connect(
      Uri.parse(realtimeUrl),
      headers: {'Authorization': apiKey},
    );

    // Listen to live transcription events
    _channel!.stream.listen((event) {
      final data = jsonDecode(event);
      if (data['text'] != null) {
        setState(() {
          _transcription = data['text'];
        });
      }
    });

    // Start recorder and stream data live
    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();

    await _recorder!.startRecorder(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 16000,
      toStream: (Uint8List buffer) async {
        if (_channel != null) {
          _channel!.sink.add(base64Encode(buffer));
        }
      },
    );
  }

  Future<void> _stopRecording() async {
    setState(() {
      isRecording = false;
      _isLoading = true;
    });

    await _recorder?.stopRecorder();
    await _recorder?.closeRecorder();

    _channel?.sink.add(jsonEncode({'terminate_session': true}));
    await _channel?.sink.close();

    final dir = await getApplicationDocumentsDirectory();
    final filePath =
        '${dir.path}/live_recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _saveRecording(filePath, _transcription);

    setState(() {
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _recorder?.closeRecorder();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        backgroundColor: Colors.indigoAccent,
        title: const Text(
          "Live Transcription",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 150,
                    width: 150,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: isRecording ? 150 : 120,
                          width: isRecording ? 150 : 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              if (isRecording)
                                BoxShadow(
                                  color: Colors.redAccent.withOpacity(0.5),
                                  blurRadius: 25,
                                  spreadRadius: 10,
                                ),
                            ],
                            gradient: LinearGradient(
                              colors: isRecording
                                  ? [Colors.redAccent, Colors.deepOrangeAccent]
                                  : [Colors.indigoAccent, Colors.blueAccent],
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 60,
                          icon: Icon(
                            isRecording ? Icons.mic : Icons.mic_none_outlined,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            isRecording
                                ? _stopRecording()
                                : _startRecording();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    isRecording
                        ? "Listening... (Live Transcription)"
                        : "Tap the mic to start recording",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 40),
                  _isLoading
                      ? Column(
                          children: [
                            LoadingAnimationWidget.waveDots(
                              color: Colors.indigoAccent,
                              size: 60,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              "Saving recording...",
                              style: TextStyle(color: Colors.black54),
                            ),
                          ],
                        )
                      : Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 8,
                                offset: Offset(2, 4),
                              ),
                            ],
                          ),
                          child: Text(
                            _transcription.isEmpty
                                ? "Your live text will appear here..."
                                : _transcription,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.black87,
                              height: 1.4,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
