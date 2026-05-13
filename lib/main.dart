import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const ProviderScope(child: AudioTranscriberApp()));
}

const openAIApiKey = String.fromEnvironment('OPENAI_API_KEY');
const backendDiarizationUrl = String.fromEnvironment('BACKEND_DIARIZATION_URL');
const _secureApiKeyStorageKey = 'openai_api_key';

class SecureApiKeyStore {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  Future<String?> read() => _storage.read(key: _secureApiKeyStorageKey);

  Future<void> save(String value) => _storage.write(key: _secureApiKeyStorageKey, value: value);

  Future<void> delete() => _storage.delete(key: _secureApiKeyStorageKey);
}

class SpeechTranscriptionService {
  Future<String> transcribeAudio({
    required String audioPath,
    required String languageCode,
    required String apiKey,
  }) async {
    final safePath = await prepareAudioFileForUpload(audioPath);
    final backendText = await _tryBackendDiarization(
      safePath: safePath,
      languageCode: languageCode,
    );
    if (backendText != null && backendText.trim().isNotEmpty) {
      return backendText;
    }

    final diarized = await _tryDiarizedTranscription(
      safePath: safePath,
      languageCode: languageCode,
      apiKey: apiKey,
    );
    if (diarized != null && diarized.trim().isNotEmpty) {
      return diarized;
    }

    final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = 'whisper-1'
      ..fields['language'] = _mapLanguage(languageCode)
      ..fields['response_format'] = 'verbose_json'
      ..files.add(await http.MultipartFile.fromPath('file', safePath));

    final streamed = await request.send().timeout(const Duration(minutes: 3));
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Falha na transcrição (${streamed.statusCode}): $body');
    }

    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final segmentsText = _formatTimestampedSegments(decoded);
      if (segmentsText.isNotEmpty) return segmentsText;
      final text = decoded['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    throw Exception('Resposta de transcrição inválida.');
  }

  Future<String?> _tryBackendDiarization({
    required String safePath,
    required String languageCode,
  }) async {
    if (backendDiarizationUrl.trim().isEmpty) return null;
    try {
      final lang = _mapLanguage(languageCode);
      final uri = Uri.parse('$backendDiarizationUrl/diarize-transcribe?language=$lang');
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', safePath));
      final streamed = await request.send().timeout(const Duration(minutes: 5));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) return null;
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final text = decoded['text']?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryDiarizedTranscription({
    required String safePath,
    required String languageCode,
    required String apiKey,
  }) async {
    try {
      final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..fields['model'] = 'gpt-4o-transcribe-diarize'
        ..fields['language'] = _mapLanguage(languageCode)
        ..fields['response_format'] = 'diarized_json'
        ..files.add(await http.MultipartFile.fromPath('file', safePath));

      final streamed = await request.send().timeout(const Duration(minutes: 3));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        return null;
      }

      final decoded = jsonDecode(body);
      final formatted = _formatDiarized(decoded);
      if (formatted.trim().isNotEmpty) return formatted;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _formatDiarized(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) return '';
    final segments = decoded['segments'];
    if (segments is! List) return '';

    final speakerMap = <String, int>{};
    var nextSpeakerNumber = 1;
    final buffer = StringBuffer();

    for (final segment in segments) {
      if (segment is! Map) continue;
      final rawSpeaker = _extractSpeakerId(segment);
      final text = segment['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      final startSeconds = _toDouble(segment['start']);

      final speakerKey = (rawSpeaker == null || rawSpeaker.isEmpty) ? 'unknown' : rawSpeaker;
      final number = speakerMap.putIfAbsent(speakerKey, () => nextSpeakerNumber++);
      final ts = _formatTimestamp(startSeconds);
      buffer.writeln('[$ts] Locutor $number: $text');
    }

    return buffer.toString().trim();
  }

  String _formatTimestampedSegments(Map<String, dynamic> decoded) {
    final segments = decoded['segments'];
    if (segments is! List) return '';

    final buffer = StringBuffer();
    for (final segment in segments) {
      if (segment is! Map) continue;
      final text = segment['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      final startSeconds = _toDouble(segment['start']);
      final ts = _formatTimestamp(startSeconds);
      buffer.writeln('[$ts] Locutor 1: $text');
    }
    return buffer.toString().trim();
  }

  String? _extractSpeakerId(Map segment) {
    final direct = segment['speaker']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;

    final speakerId = segment['speaker_id']?.toString().trim();
    if (speakerId != null && speakerId.isNotEmpty) return speakerId;

    final speakerObj = segment['speaker'];
    if (speakerObj is Map) {
      final id = speakerObj['id']?.toString().trim();
      if (id != null && id.isNotEmpty) return id;
      final label = speakerObj['label']?.toString().trim();
      if (label != null && label.isNotEmpty) return label;
      final name = speakerObj['name']?.toString().trim();
      if (name != null && name.isNotEmpty) return name;
    }

    return null;
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _formatTimestamp(double seconds) {
    final total = seconds.isFinite ? seconds.round() : 0;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final secs = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }

  String _mapLanguage(String languageCode) {
    if (languageCode.startsWith('pt')) return 'pt';
    if (languageCode.startsWith('en')) return 'en';
    if (languageCode.startsWith('es')) return 'es';
    return 'pt';
  }
}

Future<String> prepareAudioFileForUpload(String originalPath) async {
  final source = File(originalPath);
  if (!await source.exists()) {
    throw Exception('Arquivo de áudio não encontrado: $originalPath');
  }

  final bytes = await source.readAsBytes();
  if (bytes.isEmpty) {
    throw Exception('Arquivo de áudio vazio.');
  }

  final extension = _safeAudioExtension(originalPath);
  final safeName = 'upload_${DateTime.now().millisecondsSinceEpoch}.$extension';
  final safePath = '${Directory.systemTemp.path}/$safeName';
  final target = File(safePath);
  await target.writeAsBytes(bytes, flush: true);
  return target.path;
}

String _safeAudioExtension(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.m4a')) return 'm4a';
  if (lower.endsWith('.mp3')) return 'mp3';
  if (lower.endsWith('.wav')) return 'wav';
  if (lower.endsWith('.aac')) return 'aac';
  if (lower.endsWith('.flac')) return 'flac';
  return 'm4a';
}

PageRouteBuilder<void> buildCinematicRoute(Widget page) {
  return PageRouteBuilder<void>(
    pageBuilder: (context, animation, secondaryAnimation) => AppShell(child: page),
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      final slide = Tween<Offset>(
        begin: const Offset(0.03, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
      final parallax = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.02, 0),
      ).animate(CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOut));

      return SlideTransition(
        position: parallax,
        child: FadeTransition(
          opacity: fade,
          child: SlideTransition(position: slide, child: child),
        ),
      );
    },
  );
}

class AudioTranscriberApp extends StatelessWidget {
  const AudioTranscriberApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF33E8FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'AudioTranscriber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF070B14),
        textTheme: GoogleFonts.manropeTextTheme(ThemeData.dark().textTheme),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: GoogleFonts.orbitron(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide(color: Color(0xFF33E8FF), width: 1.2),
          ),
        ),
      ),
      home: const AppShell(child: HomeScreen()),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF05070C), Color(0xFF0A142A), Color(0xFF111332)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            right: -70,
            child: _GlowOrb(color: const Color(0xFF33E8FF), size: 260),
          ),
          Positioned(
            bottom: -150,
            left: -70,
            child: _GlowOrb(color: const Color(0xFF00FFA3), size: 280),
          ),
          child,
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(14)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF33E8FF).withValues(alpha: 0.09),
            blurRadius: 25,
            spreadRadius: 2,
          ),
        ],
      ),
      child: child,
    );
  }
}

enum TranscriptionSource { recorded, imported }
enum TranscriptionEngine { cloud, onDeviceLive }

class TranscriptionItem {
  TranscriptionItem({
    required this.id,
    required this.title,
    required this.text,
    required this.createdAt,
    required this.duration,
    required this.language,
    required this.source,
    required this.confidence,
    this.isFavorite = false,
    this.audioPath,
  });

  final String id;
  String title;
  String text;
  final DateTime createdAt;
  final Duration duration;
  final String language;
  final TranscriptionSource source;
  final double confidence;
  final String? audioPath;
  bool isFavorite;
}

final historyProvider = StateNotifierProvider<HistoryController, List<TranscriptionItem>>(
  (ref) => HistoryController(),
);

class HistoryController extends StateNotifier<List<TranscriptionItem>> {
  HistoryController() : super([]);

  void add(TranscriptionItem item) => state = [item, ...state];

  void remove(String id) => state = state.where((e) => e.id != id).toList();

  void toggleFavorite(String id) {
    state = [
      for (final item in state)
        if (item.id == id)
          TranscriptionItem(
            id: item.id,
            title: item.title,
            text: item.text,
            createdAt: item.createdAt,
            duration: item.duration,
            language: item.language,
            source: item.source,
            confidence: item.confidence,
            isFavorite: !item.isFavorite,
            audioPath: item.audioPath,
          )
        else
          item,
    ];
  }

  void updateText(String id, String value) {
    state = [
      for (final item in state)
        if (item.id == id)
          TranscriptionItem(
            id: item.id,
            title: item.title,
            text: value,
            createdAt: item.createdAt,
            duration: item.duration,
            language: item.language,
            source: item.source,
            confidence: item.confidence,
            isFavorite: item.isFavorite,
            audioPath: item.audioPath,
          )
        else
          item,
    ];
  }

  void updateTitle(String id, String value) {
    state = [
      for (final item in state)
        if (item.id == id)
          TranscriptionItem(
            id: item.id,
            title: value,
            text: item.text,
            createdAt: item.createdAt,
            duration: item.duration,
            language: item.language,
            source: item.source,
            confidence: item.confidence,
            isFavorite: item.isFavorite,
            audioPath: item.audioPath,
          )
        else
          item,
    ];
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String query = '';
  bool _animatedIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _animatedIn = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final allItems = ref.watch(historyProvider);
    final lower = query.toLowerCase();
    final filtered = allItems.where((e) {
      return e.title.toLowerCase().contains(lower) || e.text.toLowerCase().contains(lower);
    }).toList();

    filtered.sort((a, b) {
      if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('AudioTranscriber')),
      body: AnimatedSlide(
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        offset: _animatedIn ? Offset.zero : const Offset(0, 0.05),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 450),
          opacity: _animatedIn ? 1 : 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Column(
              children: [
            GlassCard(
              child: TextField(
                onChanged: (value) => setState(() => query = value),
                decoration: const InputDecoration(
                  hintText: 'Buscar por nome ou texto...',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await HapticFeedback.selectionClick();
                      if (!context.mounted) return;
                      await Navigator.of(context).push(buildCinematicRoute(const RecordingScreen()));
                    },
                    icon: const Icon(Icons.mic),
                    label: const Text('Gravar novo'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await HapticFeedback.selectionClick();
                      if (!context.mounted) return;
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['m4a', 'mp3', 'wav', 'aac', 'flac'],
                      );
                      if (!context.mounted || result == null || result.files.single.path == null) return;

                      await Navigator.of(context).push(
                        buildCinematicRoute(
                          TranscribingScreen(
                            audioPath: result.files.single.path!,
                            title: result.files.single.name,
                            language: 'pt-BR',
                            source: TranscriptionSource.imported,
                            engine: TranscriptionEngine.cloud,
                            onDeviceTranscript: '',
                            durationHint: const Duration(minutes: 1),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Importar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Sem transcrições ainda.'))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        final date = DateFormat('dd/MM HH:mm').format(item.createdAt);
                        return StaggeredListItem(
                          index: index,
                          child: GlassCard(
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 20,
                                backgroundColor: Colors.white.withValues(alpha: 0.14),
                                child: Icon(
                                  item.isFavorite ? Icons.push_pin : Icons.description,
                                  color: const Color(0xFF33E8FF),
                                ),
                              ),
                              title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text('${item.duration.inMinutes} min • ${item.language} • $date'),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(buildCinematicRoute(TranscriptionDetailScreen(itemId: item.id)));
                              },
                              trailing: PopupMenuButton<String>(
                                color: const Color(0xFF10172B),
                              onSelected: (value) async {
                                await HapticFeedback.selectionClick();
                                if (value == 'favorite') {
                                  ref.read(historyProvider.notifier).toggleFavorite(item.id);
                                }
                                  if (value == 'delete') {
                                    ref.read(historyProvider.notifier).remove(item.id);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'favorite',
                                    child: Text(item.isFavorite ? 'Desafixar' : 'Fixar'),
                                  ),
                                  const PopupMenuItem(value: 'delete', child: Text('Excluir')),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StaggeredListItem extends StatefulWidget {
  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  State<StaggeredListItem> createState() => _StaggeredListItemState();
}

class _StaggeredListItemState extends State<StaggeredListItem> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: 45 * widget.index);
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      offset: _visible ? Offset.zero : const Offset(0, 0.08),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 360),
        opacity: _visible ? 1 : 0,
        child: widget.child,
      ),
    );
  }
}

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  final _audioRecorder = AudioRecorder();
  final _speechToText = SpeechToText();
  final _languages = const ['pt-BR', 'en-US', 'es-ES'];
  String _language = 'pt-BR';
  TranscriptionEngine _engine = TranscriptionEngine.onDeviceLive;
  bool _recording = false;
  bool _paused = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  String? _path;
  String _livePartial = '';
  final List<String> _liveSegments = [];

  @override
  void dispose() {
    _timer?.cancel();
    _speechToText.stop();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return;
    await HapticFeedback.mediumImpact();

    final fileName = 'recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final outputPath = '${Directory.systemTemp.path}/$fileName';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: outputPath,
    );

    if (_engine == TranscriptionEngine.onDeviceLive) {
      await _startLiveRecognition();
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
    });

    setState(() {
      _recording = true;
      _paused = false;
      _elapsed = Duration.zero;
      _livePartial = '';
      _liveSegments.clear();
    });
  }

  Future<void> _startLiveRecognition() async {
    final ok = await _speechToText.initialize();
    if (!ok) return;

    await _speechToText.listen(
      localeId: _language,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
      ),
      onResult: _onSpeechResult,
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    setState(() => _livePartial = result.recognizedWords);
    if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
      final ts = _formatDuration(_elapsed);
      _liveSegments.add('[$ts] Locutor 1: ${result.recognizedWords.trim()}');
      setState(() => _livePartial = '');
    }
  }

  Future<void> _pauseOrResume() async {
    await HapticFeedback.selectionClick();
    if (_paused) {
      await _audioRecorder.resume();
      if (_engine == TranscriptionEngine.onDeviceLive) {
        await _startLiveRecognition();
      }
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _elapsed += const Duration(seconds: 1));
      });
    } else {
      await _audioRecorder.pause();
      if (_engine == TranscriptionEngine.onDeviceLive) {
        await _speechToText.stop();
      }
      _timer?.cancel();
    }
    setState(() => _paused = !_paused);
  }

  Future<void> _cancel() async {
    await HapticFeedback.lightImpact();
    _timer?.cancel();
    await _speechToText.stop();
    await _audioRecorder.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _finish() async {
    await HapticFeedback.heavyImpact();
    _timer?.cancel();
    await _speechToText.stop();
    _path = await _audioRecorder.stop();
    if (!mounted || _path == null) return;

    await Navigator.of(context).pushReplacement(
      buildCinematicRoute(
        TranscribingScreen(
          audioPath: _path!,
          title: 'Gravação ${DateFormat('dd/MM HH:mm').format(DateTime.now())}',
          language: _language,
          source: TranscriptionSource.recorded,
          engine: _engine,
          onDeviceTranscript: [
            ..._liveSegments,
            if (_livePartial.trim().isNotEmpty) '[${_formatDuration(_elapsed)}] Locutor 1: ${_livePartial.trim()}',
          ].join('\n').trim(),
          durationHint: _elapsed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pulse = _recording && !_paused;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Nova gravação')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
              child: Column(
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 1, end: pulse ? 1.04 : 1),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeInOut,
                    builder: (context, value, child) {
                      return Transform.scale(scale: value, child: child);
                    },
                    child: Text(
                      _formatDuration(_elapsed),
                      style: GoogleFonts.orbitron(
                        fontSize: 44,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF83F4FF),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(value: null),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Text(
                      _recording ? (_paused ? 'PAUSADO' : 'GRAVANDO') : 'PRONTO',
                      key: ValueKey('${_recording}_$_paused'),
                      style: GoogleFonts.orbitron(letterSpacing: 2.2, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              child: DropdownButtonFormField<String>(
                initialValue: _language,
                items: _languages.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _language = v ?? 'pt-BR'),
                decoration: const InputDecoration(labelText: 'Idioma da transcrição'),
              ),
            ),
            const SizedBox(height: 10),
            GlassCard(
              child: DropdownButtonFormField<TranscriptionEngine>(
                initialValue: _engine,
                items: const [
                  DropdownMenuItem(
                    value: TranscriptionEngine.onDeviceLive,
                    child: Text('On-device (ao vivo)'),
                  ),
                  DropdownMenuItem(
                    value: TranscriptionEngine.cloud,
                    child: Text('Cloud (API)'),
                  ),
                ],
                onChanged: (v) => setState(() => _engine = v ?? TranscriptionEngine.onDeviceLive),
                decoration: const InputDecoration(labelText: 'Motor de transcrição'),
              ),
            ),
            if (_engine == TranscriptionEngine.onDeviceLive && _recording) ...[
              const SizedBox(height: 10),
              GlassCard(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _livePartial.isEmpty ? 'Escutando fala ao vivo...' : _livePartial,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (!_recording)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: _start,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Iniciar gravação'),
                ),
              ),
            if (_recording)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pauseOrResume,
                      icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                      label: Text(_paused ? 'Retomar' : 'Pausar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _cancel,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _finish,
                      icon: const Icon(Icons.check),
                      label: const Text('Concluir'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class TranscribingScreen extends ConsumerStatefulWidget {
  const TranscribingScreen({
    super.key,
    required this.audioPath,
    required this.title,
    required this.language,
    required this.source,
    required this.engine,
    required this.onDeviceTranscript,
    required this.durationHint,
  });

  final String audioPath;
  final String title;
  final String language;
  final TranscriptionSource source;
  final TranscriptionEngine engine;
  final String onDeviceTranscript;
  final Duration durationHint;

  @override
  ConsumerState<TranscribingScreen> createState() => _TranscribingScreenState();
}

class _TranscribingScreenState extends ConsumerState<TranscribingScreen> {
  double progress = 0;
  String partial = '';
  Timer? _timer;
  String? _errorMessage;
  String? _runtimeApiKey;
  final _service = SpeechTranscriptionService();
  final _apiKeyStore = SecureApiKeyStore();

  @override
  void initState() {
    super.initState();
    _startTranscription();
  }

  Future<void> _startTranscription() async {
    setState(() {
      _errorMessage = null;
      partial = '';
      progress = 0;
    });

    if (widget.engine == TranscriptionEngine.onDeviceLive) {
      final localText = widget.onDeviceTranscript.trim();
      if (localText.isEmpty) {
        setState(() {
          _errorMessage = 'Nenhuma fala detectada no modo on-device. Tente novamente com áudio mais claro.';
        });
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      setState(() {
        progress = 1;
        partial = localText;
      });
      final id = const Uuid().v4();
      ref.read(historyProvider.notifier).add(
            TranscriptionItem(
              id: id,
              title: widget.title,
              text: localText,
              createdAt: DateTime.now(),
              duration: widget.durationHint,
              language: widget.language,
              source: widget.source,
              confidence: 0.86,
              audioPath: widget.audioPath,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        buildCinematicRoute(TranscriptionDetailScreen(itemId: id)),
        (route) => route.isFirst,
      );
      return;
    }

    final apiKey = await _resolveApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'API key ausente. Rode com --dart-define=OPENAI_API_KEY=sua_chave ou informe no app.';
      });
      return;
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 350), (timer) {
      if (!mounted) return;
      setState(() {
        if (progress < 0.9) progress += 0.025;
      });
    });

    try {
      final text = await _service.transcribeAudio(
        audioPath: widget.audioPath,
        languageCode: widget.language,
        apiKey: apiKey,
      );

      if (!mounted) return;
      _timer?.cancel();
      setState(() {
        progress = 1;
        partial = text;
      });

      final id = const Uuid().v4();
      ref.read(historyProvider.notifier).add(
            TranscriptionItem(
              id: id,
              title: widget.title,
              text: text,
              createdAt: DateTime.now(),
              duration: widget.durationHint,
              language: widget.language,
              source: widget.source,
              confidence: 0.95,
              audioPath: widget.audioPath,
            ),
          );

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        buildCinematicRoute(TranscriptionDetailScreen(itemId: id)),
        (route) => route.isFirst,
      );
    } catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Não foi possível transcrever: $e';
      });
    }
  }

  Future<String?> _resolveApiKey() async {
    if (_runtimeApiKey != null && _runtimeApiKey!.trim().isNotEmpty) return _runtimeApiKey!.trim();
    final stored = await _apiKeyStore.read();
    if (stored != null && stored.trim().isNotEmpty) {
      _runtimeApiKey = stored.trim();
      return _runtimeApiKey;
    }
    if (openAIApiKey.trim().isNotEmpty) return openAIApiKey.trim();
    return _promptApiKey();
  }

  Future<String?> _promptApiKey() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          title: const Text('Configurar API key'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: 'sk-...',
              labelText: 'OPENAI_API_KEY',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Salvar'),
            ),
            TextButton(
              onPressed: () async {
                await _apiKeyStore.delete();
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              child: const Text('Limpar chave salva'),
            ),
          ],
        );
      },
    );

    _runtimeApiKey = value;
    if (value != null && value.trim().isNotEmpty) {
      await _apiKeyStore.save(value.trim());
    }
    return value;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final percentage = (progress * 100).round();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Transcrição em andamento')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  '$percentage%',
                  key: ValueKey(percentage),
                  style: GoogleFonts.orbitron(
                    color: const Color(0xFF83F4FF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  child: _errorMessage != null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _errorMessage!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _startTranscription,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Tentar novamente'),
                            ),
                          ],
                        )
                      : partial.isEmpty
                      ? const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FuturisticShimmer(height: 14, width: 240),
                            SizedBox(height: 10),
                            FuturisticShimmer(height: 14),
                            SizedBox(height: 10),
                            FuturisticShimmer(height: 14, width: 280),
                            SizedBox(height: 10),
                            FuturisticShimmer(height: 14, width: 220),
                            SizedBox(height: 10),
                            FuturisticShimmer(height: 14),
                          ],
                        )
                      : Text(partial),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FuturisticShimmer extends StatefulWidget {
  const FuturisticShimmer({
    super.key,
    this.height = 14,
    this.width = double.infinity,
    this.radius = 8,
  });

  final double height;
  final double width;
  final double radius;

  @override
  State<FuturisticShimmer> createState() => _FuturisticShimmerState();
}

class _FuturisticShimmerState extends State<FuturisticShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final stop = _controller.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + (2 * stop), 0),
              end: Alignment(1 + (2 * stop), 0),
              colors: [
                Colors.white.withValues(alpha: 0.08),
                const Color(0xFF33E8FF).withValues(alpha: 0.18),
                Colors.white.withValues(alpha: 0.08),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TranscriptionDetailScreen extends ConsumerStatefulWidget {
  const TranscriptionDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  ConsumerState<TranscriptionDetailScreen> createState() => _TranscriptionDetailScreenState();
}

class _TranscriptionDetailScreenState extends ConsumerState<TranscriptionDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    final item = _currentItem;
    _titleController = TextEditingController(text: item?.title ?? '');
    _textController = TextEditingController(text: item?.text ?? '');
  }

  TranscriptionItem? get _currentItem {
    final items = ref.read(historyProvider);
    for (final i in items) {
      if (i.id == widget.itemId) return i;
    }
    return null;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _copyText() async {
    await HapticFeedback.selectionClick();
    await Clipboard.setData(ClipboardData(text: _textController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Texto copiado.')));
  }

  Future<void> _shareText() async {
    await HapticFeedback.lightImpact();
    await Share.share(_textController.text);
  }

  Future<void> _exportTxt() async {
    await HapticFeedback.lightImpact();
    final tmp = Directory.systemTemp;
    final file = File('${tmp.path}/${widget.itemId}.txt');
    await file.writeAsString(_textController.text);
    await Share.shareXFiles([XFile(file.path)], text: 'Transcrição exportada');
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(historyProvider).where((e) => e.id == widget.itemId).firstOrNull;
    if (item == null) {
      return const Scaffold(body: Center(child: Text('Transcrição não encontrada.')));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Transcrição'),
        actions: [
          IconButton(
            onPressed: () async {
              await HapticFeedback.selectionClick();
              ref.read(historyProvider.notifier).toggleFavorite(item.id);
            },
            icon: Icon(item.isFavorite ? Icons.push_pin : Icons.push_pin_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GlassCard(
              child: Column(
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Título'),
                    onChanged: (value) => ref.read(historyProvider.notifier).updateTitle(item.id, value),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${item.duration.inMinutes} min • ${item.language} • Confiança ${(item.confidence * 100).round()}%',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.96, end: 1),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              builder: (context, value, child) {
                return Transform.scale(scale: value, child: child);
              },
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _copyText,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _shareText,
                      icon: const Icon(Icons.share),
                      label: const Text('Compartilhar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _exportTxt,
                      icon: const Icon(Icons.file_download),
                      label: const Text('TXT'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: GlassCard(
                child: TextField(
                  controller: _textController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    alignLabelWithHint: true,
                    labelText: 'Texto transcrito',
                  ),
                  onChanged: (value) => ref.read(historyProvider.notifier).updateText(item.id, value),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final h = duration.inHours;
  final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (h > 0) return '$h:$m:$s';
  return '$m:$s';
}

extension _FirstOrNullExtension<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
