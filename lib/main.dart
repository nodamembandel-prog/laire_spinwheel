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

  // Socket untuk komunikasi antar 2 Window
  ServerSocket? _serverSocket;
  List<Socket> _clients = [];
  Socket? _clientSocket;
  String _socketBuffer = '';

  // 1. SET MODE (OPERATOR ATAU DISPLAY)
  void setMode(AppMode mode) {
    currentMode = mode;
    notifyListeners();
    if (mode == AppMode.operator) {
      _startServer();
    } else if (mode == AppMode.display) {
      _connectToServer();
    }
  }

  // ================= LOGIKA SERVER (OPERATOR) =================
  void _startServer() async {
    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 8765);
      debugPrint("Server Operator Berjalan...");
      _serverSocket!.listen((Socket client) {
        _clients.add(client);
        _broadcastState(); // Kirim data awal ke display saat dia baru connect
        
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
    for (var c in _clients) {
      c.write(jsonStr);
    }
  }

  void _broadcastSpin(int index) {
    if (_clients.isEmpty) return;
    final stateData = {'type': 'spin', 'index': index};
    final jsonStr = jsonEncode(stateData) + '\n';
    for (var c in _clients) {
      c.write(jsonStr);
    }
  }

  void _broadcastClearWinner() {
    if (_clients.isEmpty) return;
    final jsonStr = jsonEncode({'type': 'clear_winner'}) + '\n';
    for (var c in _clients) {
      c.write(jsonStr);
    }
  }

  // ================= LOGIKA CLIENT (DISPLAY) =================
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
        // Coba reconnect jika operator ditutup lalu dibuka lagi
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
        _triggerDisplaySpin(decoded['index']);
      } else if (decoded['type'] == 'clear_winner') {
        winnerName = null;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error parsing JSON: $e");
    }
  }

  // ================= AKSI OPERATOR =================
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
    
    isSpinning = true;
    winnerName = null;
    notifyListeners();
    
    int winningIndex = Random().nextInt(participants.length);
    _broadcastSpin(winningIndex);
    
    // Matikan tombol sementara agar tidak dobel klik
    Future.delayed(const Duration(seconds: 6), () {
      isSpinning = false;
      notifyListeners();
    });
  }

  // ================= AKSI DISPLAY =================
  Future<void> _triggerDisplaySpin(int index) async {
    winnerName = null;
    notifyListeners();
    
    try {
      await audioPlayer.play(AssetSource('spin_sound.mp3'));
    } catch (e) {
      debugPrint("Suara tidak ditemukan");
    }
    
    spinController.add(index);
    
    // Tampilkan pemenang setelah 5 detik (waktu putaran selesai)
    Future.delayed(const Duration(seconds: 5), () {
      winnerName = participants[index];
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
          if (state.currentMode == AppMode.selection) {
            return const ModeSelectionScreen();
          } else if (state.currentMode == AppMode.operator) {
            return const OperatorScreen();
          } else {
            return const DisplayScreen();
          }
        },
      ),
    );
  }
}

// ================= 1. LAYAR PEMILIHAN MODE =================
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
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
              ),
              onPressed: () => state.setMode(AppMode.operator),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.monitor, size: 28),
              label: const Text("BUKA SEBAGAI LAYAR DISPLAY", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                side: const BorderSide(color: Colors.orangeAccent, width: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
              ),
              onPressed: () => state.setMode(AppMode.display),
            ),
            const SizedBox(height: 20),
            const Text("Tips: Buka aplikasi ini 2 kali. Satu untuk operator, satu geser ke proyektor.", style: TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

// ================= 2. LAYAR MENU OPERATOR =================
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
      ),
      body: Row(
        children: [
          // PANEL KIRI: Pengaturan Visual & Tombol Putar
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(24.0),
              decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white12))),
              child: ListView(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 30),
                    label: Text(state.isSpinning ? 'SEDANG BERPUTAR...' : 'PUTAR RODA (Spasi)', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isSpinning ? Colors.grey : Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                    ),
                    onPressed: state.isSpinning ? null : () => state.spin(),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Tutup Popup Pemenang (ESC)'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: () => state.clearWinner(),
                  ),
                  const SizedBox(height: 40),
                  const Text("KUSTOMISASI VISUAL", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                  const Divider(),
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Judul Undian'),
                    onSubmitted: (val) => state.updateTitle(val),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.color_lens),
                    label: const Text('Ubah Warna Latar'),
                    onPressed: () => _showColorPicker(context, state),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.image),
                    label: const Text('Ganti Gambar Latar'),
                    onPressed: () => state.pickBackgroundImage(),
                  ),
                ],
              ),
            ),
          ),
          // PANEL KANAN: Daftar Peserta
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nameController,
                          decoration: const InputDecoration(hintText: 'Tambah peserta...', border: OutlineInputBorder()),
                          onSubmitted: (val) {
                            state.addParticipant(val);
                            nameController.clear();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(18), backgroundColor: Colors.orangeAccent),
                        onPressed: () {
                          state.addParticipant(nameController.text);
                          nameController.clear();
                        },
                        child: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: ListView.builder(
                      itemCount: state.participants.length,
                      itemBuilder: (context, index) {
                        return Card(
                          color: Colors.white10,
                          child: ListTile(
                            title: Text(state.participants[index]),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.redAccent),
                              onPressed: () => state.removeParticipant(index),
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
        ],
      ),
    );
  }

  void _showColorPicker(BuildContext context, AppState state) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pilih Warna'),
        content: SingleChildScrollView(
          child: ColorPicker(pickerColor: state.backgroundColor, onColorChanged: (color) => state.updateBackgroundColor(color)),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai'))],
      ),
    );
  }
}

// ================= 3. LAYAR DISPLAY (FULLSCREEN PROYEKTOR) =================
class DisplayScreen extends StatelessWidget {
  const DisplayScreen({Key? key}) : super(key: key);

  final List<Color> wheelColors = const [
    Color(0xFFE63946), Color(0xFF457B9D), Color(0xFF2A9D8F),
    Color(0xFFF4A261), Color(0xFF9D4EDD), Color(0xFFE9C46A)
  ];

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: state.backgroundColor,
          image: state.backgroundImagePath != null ? DecorationImage(image: FileImage(File(state.backgroundImagePath!)), fit: BoxFit.cover) : null,
        ),
        child: Stack(
          children: [
            // Roda dan Judul
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    state.wheelTitle,
                    style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 4.0, shadows: [Shadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 4))]),
                  ),
                  const SizedBox(height: 50),
                  SizedBox(
                    height: 600, width: 600,
                    child: FortuneWheel(
                      selected: state.spinController.stream,
                      animateFirst: false,
                      physics: CircularPanPhysics(duration: const Duration(seconds: 5), curve: Curves.decelerate),
                      items: [
                        for (int i = 0; i < state.participants.length; i++)
                          FortuneItem(
                            child: Text(state.participants[i], style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
                            style: FortuneItemStyle(color: wheelColors[i % wheelColors.length], borderColor: Colors.white, borderWidth: 3),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Logo Laire (Kecil di bawah tengah)
            Positioned(
              bottom: 20, left: 0, right: 0,
              child: Center(
                child: Image.asset('assets/Preview-4.png', height: 40, errorBuilder: (_,__,___) => const SizedBox()),
              ),
            ),

            // Animasi Pemenang Meledak (Zoom In)
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
                            padding: const EdgeInsets.symmetric(horizontal: 80, vertical: 50),
                            decoration: BoxDecoration(
                              color: Colors.orangeAccent,
                              borderRadius: BorderRadius.circular(30),
                              boxShadow: [BoxShadow(color: Colors.orange.withOpacity(0.5), blurRadius: 100, spreadRadius: 20)],
                              border: Border.all(color: Colors.white, width: 5),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text("SELAMAT KEPADA", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white70, letterSpacing: 5)),
                                const SizedBox(height: 10),
                                Text(
                                  state.winnerName!.toUpperCase(),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 90, fontWeight: FontWeight.w900, color: Colors.white, shadows: [Shadow(color: Colors.black54, offset: Offset(2, 4), blurRadius: 4)]),
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
      ),
    );
  }
}
