// lib/recording_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sound_stream/sound_stream.dart';
import 'package:web_socket_channel/io.dart';
import 'package:path_provider/path_provider.dart';

/// RecordingService:
/// - initializes mic recorder
/// - starts streaming raw PCM bytes to AssemblyAI realtime websocket
/// - writes incoming audio PCM bytes to a temporary raw file (then builds .wav on stop)
/// - exposes [transcriptStream] for live transcript updates
class RecordingService {
  final RecorderStream _recorder = RecorderStream();
  IOWebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _audioSub;

  // Where live transcripts will be sent
  final StreamController<String> _transcriptController = StreamController.broadcast();
  Stream<String> get transcriptStream => _transcriptController.stream;

  // Collect raw PCM bytes to file
  RandomAccessFile? _rawFileRAF;
  File? _rawFile;
  String? _rawFilePath;

  // To collect final "best" transcript (set as last final message from server)
  String lastFinalTranscript = '';

  // For debug printing and control
  bool isInitialized = false;
  bool isRecording = false;

  RecordingService();

  Future<void> initializeRecorder() async {
    print('[RecordingService] initializeRecorder()');
    try {
      await _recorder.initialize();
      print('[RecordingService] recorder initialized. audioStream available? ${_recorder.audioStream != null}');
      isInitialized = true;
    } catch (e, st) {
      print('[RecordingService] initialize error: $e\n$st');
      rethrow;
    }
  }

  Future<String> _createRawFilePath() async {
    final d = await getApplicationDocumentsDirectory();
    final path = '${d.path}/pcm_${DateTime.now().millisecondsSinceEpoch}.raw';
    return path;
  }

  Future<void> _openRawFileForAppend() async {
    _rawFilePath = await _createRawFilePath();
    _rawFile = File(_rawFilePath!);
    if (!await _rawFile!.exists()) {
      await _rawFile!.create(recursive: true);
    }
    _rawFileRAF = await _rawFile!.open(mode: FileMode.append);
    print('[RecordingService] openRawFileForAppend at $_rawFilePath');
  }

  /// Start realtime: opens WS, starts recorder, streams PCM16 bytes to WS and writes to raw file
  /// [assemblyApiKey] is your AssemblyAI API key (string)
  Future<void> startRealtime(String assemblyApiKey, {int sampleRate = 16000}) async {
    print('[RecordingService] startRealtime()');
    if (!isInitialized) {
      await initializeRecorder();
    }

    // create raw file to store PCM bytes
    await _openRawFileForAppend();

    // Build websocket URI with requested sample rate
    final uri = Uri.parse('wss://api.assemblyai.com/v2/realtime?sample_rate=$sampleRate');
    print('[RecordingService] connecting to AssemblyAI realtime WS: $uri');

    try {
      // Connect with Authorization header
      final socket = await WebSocket.connect(uri.toString(), headers: {
        'Authorization': assemblyApiKey,
      });
      print('[RecordingService] WebSocket connected');
      _channel = IOWebSocketChannel(socket);

      // Listen to server messages
      _channel!.stream.listen((dynamic message) {
        print('[RecordingService] WS message -> $message');
        // Parse JSON (AssemblyAI sends JSON objects)
        try {
          final m = json.decode(message.toString());
          // Server messages vary; common keys: 'text', 'message_type', 'is_final' or 'type'
          String? text;
          if (m is Map<String, dynamic>) {
            // Try multiple patterns
            if (m.containsKey('text')) text = m['text']?.toString();
            else if (m.containsKey('message')) text = m['message']?.toString();
            else if (m.containsKey('payload') && m['payload'] is Map && m['payload'].containsKey('text')) {
              text = m['payload']['text']?.toString();
            } else if (m.containsKey('type') && m['type'] == 'final') {
              // some formats
              text = m.toString();
            } else {
              // fallback: stringify
              text = m.toString();
            }

            // If there is a flag 'is_final' or similar, update lastFinalTranscript
            if (m.containsKey('is_final') && m['is_final'] == true && text != null) {
              lastFinalTranscript = text;
              print('[RecordingService] Updated lastFinalTranscript: $lastFinalTranscript');
            }

            // Push to transcript stream for UI
            if (text != null) {
              _transcriptController.add(text);
            }
          } else {
            // Non-map messages
            _transcriptController.add(message.toString());
          }
        } catch (e) {
          print('[RecordingService] Error parsing WS message: $e');
          _transcriptController.add(message.toString());
        }
      }, onError: (e) {
        print('[RecordingService] WS listen error: $e');
      }, onDone: () {
        print('[RecordingService] WS done/closed by server');
      });

      // Start microphone and pipe audio frames
      print('[RecordingService] Starting microphone recorder...');
      _recorder.start();
      isRecording = true;

      // audioStream emits Uint8List buffers (PCM)
      _audioSub = _recorder.audioStream?.listen((Uint8List buffer) async {
        if (buffer.isEmpty) return;
        try {
          // Write to raw file
          if (_rawFileRAF != null) {
            await _rawFileRAF!.writeFrom(buffer);
            // do not flush too often; writeFrom is ok for small buffers
          }
          // Send binary frame to websocket (binary frames)
          if (_channel != null) {
            _channel!.sink.add(buffer);
            print('[RecordingService] sent ${buffer.length} bytes to WS');
          }
        } catch (e) {
          print('[RecordingService] Error in audio frame handling: $e');
        }
      }, onError: (e) {
        print('[RecordingService] audioStream error: $e');
      }, onDone: () {
        print('[RecordingService] audioStream done');
      });

      print('[RecordingService] startRealtime -> Done starting');
    } catch (e, st) {
      print('[RecordingService] Error connecting/starting realtime: $e\n$st');
      rethrow;
    }
  }

  /// Stop streaming & recording
  /// Returns path to final WAV file (converted from raw PCM)
  Future<String?> stopRealtimeAndFinalizeWav({int sampleRate = 16000, int channels = 1}) async {
    print('[RecordingService] stopRealtimeAndFinalizeWav()');
    try {
      // Stop receiving audio frames
      await _audioSub?.cancel();
      _audioSub = null;

      // Stop recorder
      try {
        await _recorder.stop();
        print('[RecordingService] recorder stopped');
      } catch (e) {
        print('[RecordingService] error stopping recorder: $e');
      }
      isRecording = false;

      // Close raw file raf
      await _rawFileRAF?.close();
      _rawFileRAF = null;

      // Close websocket gracefully
      try {
        await _channel?.sink.close();
        print('[RecordingService] WebSocket sink closed');
      } catch (e) {
        print('[RecordingService] error closing websocket sink: $e');
      }
      _channel = null;

      // Convert raw PCM file to WAV
      if (_rawFilePath == null) {
        print('[RecordingService] No raw file path; nothing to finalize');
        return null;
      }
      final rawFile = File(_rawFilePath!);
      if (!await rawFile.exists()) {
        print('[RecordingService] raw file does not exist at $_rawFilePath');
        return null;
      }
      final rawBytes = await rawFile.readAsBytes();
      print('[RecordingService] raw bytes length: ${rawBytes.length}');

      final wavPath = await _writeWavFileFromPcm(rawBytes, sampleRate: sampleRate, channels: channels);
      print('[RecordingService] WAV file created at: $wavPath');

      // Optionally delete raw file
      try {
        await rawFile.delete();
        print('[RecordingService] deleted temp raw file $_rawFilePath');
      } catch (e) {
        print('[RecordingService] could not delete raw file: $e');
      }

      return wavPath;
    } catch (e, st) {
      print('[RecordingService] stopRealtimeAndFinalizeWav error: $e\n$st');
      return null;
    } finally {
      // reset internal raw file path for next recording
      _rawFilePath = null;
    }
  }

  /// Helper: write WAV header + pcm bytes -> file
  Future<String> _writeWavFileFromPcm(Uint8List pcmBytes, {int sampleRate = 16000, int channels = 1}) async {
    final d = await getApplicationDocumentsDirectory();
    final wavPath = '${d.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    final wavFile = File(wavPath);
    final out = await wavFile.open(mode: FileMode.write);

    final byteRate = sampleRate * channels * 2; // 16-bit PCM -> 2 bytes per sample
    final blockAlign = (channels * 2);

    // RIFF header
    // ChunkID "RIFF"
    out.writeFromSync(utf8.encode('RIFF'));
    // ChunkSize (36 + Subchunk2Size) -> uint32 little-endian
    final chunkSize = 36 + pcmBytes.length;
    out.writeFromSync(_uint32ToBytesLE(chunkSize));
    // Format "WAVE"
    out.writeFromSync(utf8.encode('WAVE'));

    // Subchunk1ID "fmt "
    out.writeFromSync(utf8.encode('fmt '));
    // Subchunk1Size 16 for PCM
    out.writeFromSync(_uint32ToBytesLE(16));
    // AudioFormat 1 for PCM (uint16)
    out.writeFromSync(_uint16ToBytesLE(1));
    // NumChannels (uint16)
    out.writeFromSync(_uint16ToBytesLE(channels));
    // SampleRate (uint32)
    out.writeFromSync(_uint32ToBytesLE(sampleRate));
    // ByteRate (uint32)
    out.writeFromSync(_uint32ToBytesLE(byteRate));
    // BlockAlign (uint16)
    out.writeFromSync(_uint16ToBytesLE(blockAlign));
    // BitsPerSample (uint16) -> 16
    out.writeFromSync(_uint16ToBytesLE(16));

    // Subchunk2ID "data"
    out.writeFromSync(utf8.encode('data'));
    // Subchunk2Size (uint32) -> pcmBytes.length
    out.writeFromSync(_uint32ToBytesLE(pcmBytes.length));
    // Data
    await out.writeFrom(pcmBytes);
    await out.close();

    return wavPath;
  }

  List<int> _uint32ToBytesLE(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  List<int> _uint16ToBytesLE(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  void dispose() {
    _transcriptController.close();
  }
}
