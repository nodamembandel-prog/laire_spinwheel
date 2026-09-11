import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
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
  
  List<String> participants = ['Peserta 1', 'Peserta 2', 'Peserta 3', 'Peserta 4', 'Peserta 5', 'Peserta 6'];
  List<String> winners = []; // Daftar Pemenang
  
  String wheelTitle = "LAIRE CREATIVE UNDIAN";
  Color backgroundColor = const Color(0xFF0F172A);
  
  // Menggunakan Base64 agar tembus keamanan Sandbox macOS
  String? backgroundBase64;
  
  bool isSpinning = false;
  bool showWinnerList = true; // Toggle panel pemenang
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
      'winners': winners,
      'showWinnerList': showWinnerList,
      'bgColor': backgroundColor.value,
      'bgBase64': backgroundBase64,
    };
    final jsonStr = jsonEncode(stateData) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  void _broadcastSpin(int index) {
    if (_clients.isEmpty) return;
    final jsonStr = jsonEncode({'type': 'spin', 'index': index}) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  void _broadcastClearPopup() {
    if (_clients.isEmpty) return;
    final jsonStr = jsonEncode({'type': 'clear_popup'}) + '\n';
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
        winners = List<String>.from(decoded['winners']);
        showWinnerList = decoded['showWinnerList'];
        backgroundColor = Color(decoded['bgColor']);
        backgroundBase64 = decoded['bgBase64'];
        notifyListeners();
      } else if (decoded['type'] == 'spin') {
        _triggerSpin(decoded['index']);
      } else if (decoded['type'] == 'clear_popup') {
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
    if (participants.isNotEmpty) {
      participants.removeAt(index);
      _broadcastState();
      notifyListeners();
    }
  }

  void clearAllWinners() {
    winners.clear();
    _broadcastState();
    notifyListeners();
  }

  void toggleWinnerList() {
    showWinnerList = !showWinnerList;
    _broadcastState();
    notifyListeners();
  }

  void updateTitle(String newTitle) {
    wheelTitle = newTitle;
    _broadcastState();
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    backgroundColor = color;
    backgroundBase64 = null; // Reset gambar jika warna dipilih
    _broadcastState();
    notifyListeners();
  }

  Future<void> pickBackgroundImage() async {
    // Membaca file sebagai bytes agar bisa di-encode ke Base64 (Tembus Sandbox)
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result != null) {
      Uint8List? fileBytes = result.files.single.bytes;
      if (fileBytes == null && result.files.single.path != null) {
        fileBytes = await File(result.files.single.path!).readAsBytes();
      }
      
      if (fileBytes != null) {
        backgroundBase64 = base64Encode(fileBytes);
        _broadcastState();
        notifyListeners();
      }
    }
  }

  void clearPopup() {
    winnerName = null;
    _broadcastClearPopup();
    notifyListeners();
  }

  void spin() {
    if (isSpinning || participants.isEmpty) return;
    int winningIndex = Random().nextInt(participants.length);
    _broadcastSpin(winningIndex); 
    _triggerSpin(winningIndex);   
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
    
    // Setelah putaran berhenti (5 detik)
    Future.delayed(const Duration(seconds: 5), () {
      if (participants.isNotEmpty && index < participants.length) {
        String won = participants[index];
        winnerName = won;
        winners.add(won); // Masukkan ke daftar pemenang
        participants.removeAt(index); // Hapus dari roda
      }
      isSpinning = false;
      
      // Paksa sync ulang dari server agar list benar-benar sama
      if (currentMode == AppMode.operator) {
        _broadcastState();
      }
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
                  const SizedBox(height: 15),
                  ElevatedButton.icon(icon: const Icon(Icons.color_lens), label: const Text('Ubah Warna Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)), onPressed: () => _showColorPicker(context, state)),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(icon: const Icon(Icons.image), label: const Text('Ganti Gambar Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)), onPressed: () => state.pickBackgroundImage()),
                  const SizedBox(height: 40),
                  
                  const Text("KONTROL LAYAR", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                  const Divider(),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    title: const Text("Tampilkan Box Pemenang"),
                    activeColor: Colors.orangeAccent,
                    value: state.showWinnerList,
                    onChanged: (val) => state.toggleWinnerList(),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Tutup Popup Pemenang (ESC)'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, padding: const EdgeInsets.all(16)),
                    onPressed: () => state.clearPopup(),
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
                      onPressed: (state.isSpinning || state.participants.isEmpty) ? null : () => state.spin(),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // KOLOM 3: DAFTAR PESERTA & PEMENANG
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.white12))),
              child: Column(
                children: [
                  // BAGIAN PESERTA
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("PESERTA RODA", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                      Text("Total: ${state.participants.length}", style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(),
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
                  const SizedBox(height: 10),
                  Expanded(
                    flex: 3,
                    child: ListView.builder(
                      itemCount: state.participants.length,
                      itemBuilder: (context, index) {
                        return Card(
                          color: Colors.white10,
                          margin: const EdgeInsets.only(bottom: 5),
                          child: ListTile(
                            dense: true,
                            title: Text(state.participants[index]),
                            trailing: IconButton(icon: const Icon(Icons.close, color: Colors.redAccent, size: 18), onPressed: () => state.removeParticipant(index)),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // BAGIAN PEMENANG
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("TELAH MENANG", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                      Text("Total: ${state.winners.length}", style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    flex: 2,
                    child: ListView.builder(
                      itemCount: state.winners.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.emoji_events, color: Colors.amber, size: 18),
                          title: Text(state.winners[index], style: const TextStyle(color: Colors.white70)),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
                      onPressed: () => state.clearAllWinners(),
                      child: const Text("Reset Data Pemenang"),
                    ),
                  )
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

// ================= KOMPONEN RODA & TAMPILAN DISPLAY =================
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
        image: state.backgroundBase64 != null 
            ? DecorationImage(image: MemoryImage(base64Decode(state.backgroundBase64!)), fit: BoxFit.cover) 
            : null,
      ),
      child: Stack(
        children: [
          // RODA & JUDUL UTAMA
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
                    shadows: const [Shadow(color: Colors.black, blurRadius: 20, offset: Offset(0, 4))]
                  ),
                ),
                SizedBox(height: isPreview ? 20 : 50),
                if (state.participants.isNotEmpty)
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
                  )
                else
                  Text("Belum ada peserta", style: TextStyle(color: Colors.white54, fontSize: isPreview ? 16 : 30)),
              ],
            ),
          ),

          // OVERLAY DAFTAR PEMENANG (KANAN)
          if (state.showWinnerList && state.winners.isNotEmpty)
            Positioned(
              top: isPreview ? 20 : 50,
              bottom: isPreview ? 80 : 150, // Hindari menabrak logo di bawah
              right: isPreview ? 10 : 40,
              child: Container(
                width: isPreview ? 120 : 300,
                padding: EdgeInsets.all(isPreview ? 10 : 25),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.orangeAccent, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.emoji_events, color: Colors.amber, size: isPreview ? 14 : 30),
                        SizedBox(width: isPreview ? 5 : 10),
                        Text("PEMENANG", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isPreview ? 12 : 24)),
                      ],
                    ),
                    const Divider(color: Colors.orangeAccent),
                    Expanded(
                      child: ListView.builder(
                        itemCount: state.winners.length,
                        itemBuilder: (context, i) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Text("${i + 1}. ${state.winners[i]}", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: isPreview ? 11 : 22)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // LOGO DAN TEKS LAIRE CREATIVE STUDIO (BAWAH TENGAH SOLID PILL)
          Positioned(
            bottom: isPreview ? 10 : 30, 
            left: 0, 
            right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: isPreview ? 15 : 30, vertical: isPreview ? 5 : 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7), // Pill solid transparan hitam
                  borderRadius: BorderRadius.circular(50), // Membentuk kapsul
                  border: Border.all(color: Colors.white24, width: 1),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/Preview-4.png', height: isPreview ? 20 : 40, errorBuilder: (_,__,___) => const SizedBox()),
                    SizedBox(width: isPreview ? 8 : 15),
                    Text(
                      "LAIRE CREATIVE STUDIO",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: isPreview ? 1.5 : 3.0,
                        fontSize: isPreview ? 10 : 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // POPUP ANIMASI ZOOM IN PEMENANG
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
                                style: TextStyle(fontSize: isPreview ? 35 : 90, fontWeight: FontWeight.w900, color: Colors.white, shadows: const [Shadow(color: Colors.black54, offset: Offset(2, 4), blurRadius: 4)]),
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
