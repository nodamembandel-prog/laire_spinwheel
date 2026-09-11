import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fortune_wheel/flutter_fortune_wheel.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const LaireSpinwheelApp(),
    ),
  );
}

enum AppMode { selection, operator, display }

class AppState extends ChangeNotifier {
  AppMode currentMode = AppMode.selection;
  
  List<String> participants = ['Peserta 1', 'Peserta 2', 'Peserta 3', 'Peserta 4'];
  String wheelTitle = "LAIRE CREATIVE UNDIAN";
  Color backgroundColor = const Color(0xFF0F172A);
  String? backgroundImagePath;
  
  bool isSpinning = false;
  String? winnerName;
  
  final StreamController<int> spinController = StreamController<int>.broadcast();
  final AudioPlayer audioPlayer = AudioPlayer();

  ServerSocket? _serverSocket;
  final List<Socket> _clients = [];
  Socket? _clientSocket;
  String _socketBuffer = '';

  void setMode(AppMode mode) {
    currentMode = mode;
    notifyListeners();
    if (mode == AppMode.operator) {
      _startServer();
    } else if (mode == AppMode.display) {
      _connectToServer();
    }
  }

  // ================= SERVER (OPERATOR) =================
  void _startServer() async {
    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 8765);
      _serverSocket!.listen((Socket client) {
        _clients.add(client);
        _broadcastState(); 
        client.listen((data) {}, onDone: () => _clients.remove(client));
      });
    } catch (e) {
      debugPrint("Gagal membuat server: $e");
    }
  }

  void _broadcastState() {
    if (_clients.isEmpty) return;
    final stateData = {
      'type': 'sync',
      'title': wheelTitle,
      'participants': participants,
      'bgColor': backgroundColor.value,
      'bgImage': backgroundImagePath,
    };
    final jsonStr = jsonEncode(stateData) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  void _broadcastSpin(int index) {
    if (_clients.isEmpty) return;
    final jsonStr = jsonEncode({'type': 'spin', 'index': index}) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  void _broadcastClearWinner() {
    if (_clients.isEmpty) return;
    final jsonStr = jsonEncode({'type': 'clear_winner'}) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  // ================= CLIENT (DISPLAY) =================
  void _connectToServer() async {
    try {
      _clientSocket = await Socket.connect(InternetAddress.loopbackIPv4, 8765);
      _clientSocket!.listen((List<int> data) {
        _socketBuffer += utf8.decode(data);
        while (_socketBuffer.contains('\n')) {
          int index = _socketBuffer.indexOf('\n');
          String line = _socketBuffer.substring(0, index);
          _socketBuffer = _socketBuffer.substring(index + 1);
          if (line.trim().isNotEmpty) _processCommand(line);
        }
      }, onDone: () {
        Future.delayed(const Duration(seconds: 2), _connectToServer);
      });
    } catch (e) {
      Future.delayed(const Duration(seconds: 2), _connectToServer);
    }
  }

  void _processCommand(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded['type'] == 'sync') {
        wheelTitle = decoded['title'];
        participants = List<String>.from(decoded['participants']);
        backgroundColor = Color(decoded['bgColor']);
        backgroundImagePath = decoded['bgImage'];
        notifyListeners();
      } else if (decoded['type'] == 'spin') {
        _triggerSpin(decoded['index']);
      } else if (decoded['type'] == 'clear_winner') {
        winnerName = null;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error parsing JSON: $e");
    }
  }

  // ================= AKSI KONTROL =================
  void addParticipant(String name) {
    if (name.trim().isNotEmpty) {
      participants.add(name.trim());
      _broadcastState();
      notifyListeners();
    }
  }

  void removeParticipant(int index) {
    if (participants.length > 2) {
      participants.removeAt(index);
      _broadcastState();
      notifyListeners();
    }
  }

  void updateTitle(String newTitle) {
    wheelTitle = newTitle;
    _broadcastState();
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    backgroundColor = color;
    backgroundImagePath = null;
    _broadcastState();
    notifyListeners();
  }

  Future<void> pickBackgroundImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      backgroundImagePath = result.files.single.path;
      _broadcastState();
      notifyListeners();
    }
  }

  void clearWinner() {
    winnerName = null;
    _broadcastClearWinner();
    notifyListeners();
  }

  void spin() {
    if (isSpinning || participants.length < 2) return;
    int winningIndex = Random().nextInt(participants.length);
    _broadcastSpin(winningIndex); // Kirim ke Layar 2
    _triggerSpin(winningIndex);   // Mainkan di Live Preview Operator
  }

  Future<void> _triggerSpin(int index) async {
    isSpinning = true;
    winnerName = null;
    notifyListeners();
    
    try {
      await audioPlayer.play(AssetSource('spin_sound.mp3'));
    } catch (e) {
      debugPrint("Suara tidak ditemukan");
    }
    
    spinController.add(index);
    
    Future.delayed(const Duration(seconds: 5), () {
      winnerName = participants[index];
      isSpinning = false;
      notifyListeners();
    });
  }
}

class LaireSpinwheelApp extends StatelessWidget {
  const LaireSpinwheelApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laire Spinwheel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Segoe UI'),
      home: Consumer<AppState>(
        builder: (context, state, child) {
          if (state.currentMode == AppMode.selection) return const ModeSelectionScreen();
          if (state.currentMode == AppMode.operator) return const OperatorScreen();
          return const Scaffold(body: SpinwheelView(isPreview: false));
        },
      ),
    );
  }
}

// ================= LAYAR PEMILIHAN MODE =================
class ModeSelectionScreen extends StatelessWidget {
  const ModeSelectionScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context, listen: false);
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/Preview-4.png', height: 120, errorBuilder: (_,__,___) => const SizedBox()),
            const SizedBox(height: 50),
            const Text("PILIH FUNGSI WINDOW INI", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings, size: 28),
              label: const Text("BUKA SEBAGAI MENU OPERATOR", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20)),
              onPressed: () => state.setMode(AppMode.operator),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.monitor, size: 28),
              label: const Text("BUKA SEBAGAI LAYAR DISPLAY", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), side: const BorderSide(color: Colors.orangeAccent, width: 2)),
              onPressed: () => state.setMode(AppMode.display),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= LAYAR MENU OPERATOR (3 KOLOM) =================
class OperatorScreen extends StatelessWidget {
  const OperatorScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final TextEditingController nameController = TextEditingController();
    final TextEditingController titleController = TextEditingController(text: state.wheelTitle);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LAIRE STUDIO - KONTROL OPERATOR', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
        backgroundColor: Colors.black,
        actions: [
          Center(child: Padding(padding: const EdgeInsets.only(right: 20), child: Text(state.isSpinning ? "🔴 LIVE: BERPUTAR" : "🟢 STANDBY", style: TextStyle(color: state.isSpinning ? Colors.red : Colors.green, fontWeight: FontWeight.bold, fontSize: 16)))),
        ],
      ),
      body: Row(
        children: [
          // KOLOM 1: PENGATURAN VISUAL
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white12))),
              child: ListView(
                children: [
                  const Text("KUSTOMISASI VISUAL", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                  const Divider(),
                  const SizedBox(height: 10),
                  TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Judul Undian', border: OutlineInputBorder()), onSubmitted: (val) => state.updateTitle(val)),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(icon: const Icon(Icons.color_lens), label: const Text('Ubah Warna Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)), onPressed: () => _showColorPicker(context, state)),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(icon: const Icon(Icons.image), label: const Text('Ganti Gambar Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)), onPressed: () => state.pickBackgroundImage()),
                  const SizedBox(height: 40),
                  const Text("KONTROL LAYAR", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                  const Divider(),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Tutup Pemenang (ESC)'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, padding: const EdgeInsets.all(16)),
                    onPressed: () => state.clearWinner(),
                  ),
                ],
              ),
            ),
          ),
          
          // KOLOM 2: LIVE PREVIEW & TOMBOL PUTAR
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.monitor, color: Colors.white54, size: 18),
                      SizedBox(width: 8),
                      Text("LIVE PREVIEW", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.white54)),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24, width: 2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: const SpinwheelView(isPreview: true),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 60,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 30),
                      label: Text(state.isSpinning ? 'SEDANG BERPUTAR...' : 'PUTAR RODA SEKARANG', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: state.isSpinning ? Colors.grey : Colors.green,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: state.isSpinning ? null : () => state.spin(),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // KOLOM 3: DAFTAR PESERTA
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.white12))),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("DAFTAR PESERTA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                      Text("Total: ${state.participants.length}", style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nameController,
                          decoration: const InputDecoration(hintText: 'Nama...', border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10)),
                          onSubmitted: (val) { state.addParticipant(val); nameController.clear(); },
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(14), backgroundColor: Colors.orangeAccent),
                        onPressed: () { state.addParticipant(nameController.text); nameController.clear(); },
                        child: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Expanded(
                    child: ListView.builder(
                      itemCount: state.participants.length,
                      itemBuilder: (context, index) {
                        return Card(
                          color: Colors.white10,
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            dense: true,
                            title: Text(state.participants[index]),
                            trailing: IconButton(icon: const Icon(Icons.close, color: Colors.redAccent, size: 20), onPressed: () => state.removeParticipant(index)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pilih Warna'),
        content: SingleChildScrollView(child: ColorPicker(pickerColor: state.backgroundColor, onColorChanged: (color) => state.updateBackgroundColor(color))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai'))],
      ),
    );
  }
}

// ================= KOMPONEN RODA (Bisa dipakai di Display & Preview) =================
class SpinwheelView extends StatelessWidget {
  final bool isPreview;
  const SpinwheelView({Key? key, required this.isPreview}) : super(key: key);

  final List<Color> wheelColors = const [
    Color(0xFFE63946), Color(0xFF457B9D), Color(0xFF2A9D8F),
    Color(0xFFF4A261), Color(0xFF9D4EDD), Color(0xFFE9C46A)
  ];

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: state.backgroundColor,
        image: state.backgroundImagePath != null ? DecorationImage(image: FileImage(File(state.backgroundImagePath!)), fit: BoxFit.cover) : null,
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  state.wheelTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isPreview ? 24 : 48, 
                    fontWeight: FontWeight.w900, 
                    color: Colors.white, 
                    letterSpacing: isPreview ? 2.0 : 4.0, 
                    shadows: const [Shadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 4))]
                  ),
                ),
                SizedBox(height: isPreview ? 20 : 50),
                SizedBox(
                  height: isPreview ? 300 : 600, 
                  width: isPreview ? 300 : 600,
                  child: FortuneWheel(
                    selected: state.spinController.stream,
                    animateFirst: false,
                    physics: CircularPanPhysics(duration: const Duration(seconds: 5), curve: Curves.decelerate),
                    items: [
                      for (int i = 0; i < state.participants.length; i++)
                        FortuneItem(
                          child: Text(state.participants[i], style: TextStyle(fontSize: isPreview ? 14 : 26, fontWeight: FontWeight.bold, color: Colors.white)),
                          style: FortuneItemStyle(color: wheelColors[i % wheelColors.length], borderColor: Colors.white, borderWidth: isPreview ? 1 : 3),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: isPreview ? 10 : 20, left: 0, right: 0,
            child: Center(child: Image.asset('assets/Preview-4.png', height: isPreview ? 25 : 40, errorBuilder: (_,__,___) => const SizedBox())),
          ),
          if (state.winnerName != null)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.8),
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.1, end: 1.0),
                    duration: const Duration(milliseconds: 1000),
                    curve: Curves.elasticOut,
                    builder: (context, scale, child) {
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: isPreview ? 30 : 80, vertical: isPreview ? 20 : 50),
                          decoration: BoxDecoration(
                            color: Colors.orangeAccent,
                            borderRadius: BorderRadius.circular(isPreview ? 15 : 30),
                            border: Border.all(color: Colors.white, width: isPreview ? 2 : 5),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("SELAMAT KEPADA", style: TextStyle(fontSize: isPreview ? 12 : 24, fontWeight: FontWeight.bold, color: Colors.white70)),
                              SizedBox(height: isPreview ? 5 : 10),
                              Text(
                                state.winnerName!.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: isPreview ? 40 : 90, fontWeight: FontWeight.w900, color: Colors.white, shadows: const [Shadow(color: Colors.black54, offset: Offset(2, 4), blurRadius: 4)]),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
