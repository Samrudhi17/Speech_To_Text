import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const SpeakToTextPage(),
    );
  }
}

class SpeakToTextPage extends StatefulWidget {
  const SpeakToTextPage({super.key});

  @override
  State<SpeakToTextPage> createState() => _SpeakToTextPageState();
}

class _SpeakToTextPageState extends State<SpeakToTextPage> {
  FlutterSoundRecorder? _recorder;
  bool isRecording = false;
  String? _filePath;
  String _transcription = "";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    _recorder = FlutterSoundRecorder();
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      throw Exception('Microphone permission not granted');
    }
    await _recorder!.openRecorder();
  }

  Future<void> _startRecording() async {
    final tempDir = await getTemporaryDirectory();
    _filePath = '${tempDir.path}/recording.m4a';

    await _recorder!.startRecorder(toFile: _filePath, codec: Codec.aacMP4);

    setState(() {
      isRecording = true;
      _transcription = "";
    });
  }

  Future<void> _stopRecording() async {
    await Future.delayed(const Duration(milliseconds: 500));
    await _recorder!.stopRecorder();

    setState(() {
      isRecording = false;
    });

    if (_filePath != null) {
      await _sendToAssemblyAI(_filePath!);
    }
  }



  Future<void> _sendToAssemblyAI(String path) async {
  setState(() {
    _isLoading = true;
  });

  const String apiKey = 'bc5bee7b4bff42e1a7b87ed6501ed3d5';

  try {
    // 1️⃣ Upload the audio file (fixed)
    final file = File(path);
    final uri = Uri.parse('https://api.assemblyai.com/v2/upload');
    final request = http.Request("POST", uri);
    request.headers['authorization'] = apiKey;
    request.bodyBytes = await file.readAsBytes();

    final uploadResponse = await request.send();
    final uploadResponseBody = await uploadResponse.stream.bytesToString();

    if (uploadResponse.statusCode != 200) {
      throw Exception('Upload failed: $uploadResponseBody');
    }

    final uploadUrl = jsonDecode(uploadResponseBody)['upload_url'];

    // 2️⃣ Create transcription job
    final transcriptionRequest = await http.post(
      Uri.parse('https://api.assemblyai.com/v2/transcript'),
      headers: {
        'authorization': apiKey,
        'content-type': 'application/json',
      },
      body: jsonEncode({'audio_url': uploadUrl}),
    );

    if (transcriptionRequest.statusCode != 200) {
      throw Exception('Transcription request failed: ${transcriptionRequest.body}');
    }

    final transcriptId = jsonDecode(transcriptionRequest.body)['id'];

    // 3️⃣ Poll status until completed
    String status = '';
    String text = '';
    while (status != 'completed') {
      await Future.delayed(const Duration(seconds: 3));
      final pollingResponse = await http.get(
        Uri.parse('https://api.assemblyai.com/v2/transcript/$transcriptId'),
        headers: {'authorization': apiKey},
      );

      final body = jsonDecode(pollingResponse.body);
      status = body['status'];
      if (status == 'completed') {
        text = body['text'];
        break;
      } else if (status == 'error') {
        throw Exception('Transcription error: ${body['error']}');
      }
    }

    setState(() {
      _transcription = text;
      _isLoading = false;
    });
  } catch (e) {
    setState(() {
      _transcription = "Failed to transcribe. Try again.\nError: $e";
      _isLoading = false;
    });
  }
}


  @override
  void dispose() {
    _recorder?.closeRecorder();
    _recorder = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text("Voice Assistant"),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              height: 40,
              child: isRecording
                  ? LoadingAnimationWidget.staggeredDotsWave(
                      color: Colors.green,
                      size: 80,
                    )
                  : const SizedBox(height: 40),
            ),
            const SizedBox(height: 30),
            const Text(
              'Transcription:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            if (_isLoading)
              LoadingAnimationWidget.threeRotatingDots(
                  color: Colors.blue, size: 60)
            else
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.grey[200],
                ),
                child: Text(
                  _transcription,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          isRecording ? _stopRecording() : _startRecording();
        },
        tooltip: 'Mic',
        child: Icon(isRecording ? Icons.mic : Icons.mic_off),
      ),
    );
  }
}
