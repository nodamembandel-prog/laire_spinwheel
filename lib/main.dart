import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const LaireRaffleApp(),
    ),
  );
}

enum AppMode { selection, operator, display }

class WinnerData {
  String name;
  String status; // 'MENUNGGU', 'SAH', 'HANGUS'
  WinnerData({required this.name, this.status = 'MENUNGGU'});
  
  Map<String, dynamic> toJson() => {'name': name, 'status': status};
  factory WinnerData.fromJson(Map<String, dynamic> json) => WinnerData(name: json['name'], status: json['status']);
}

class AppState extends ChangeNotifier {
  AppMode currentMode = AppMode.selection;
  
  List<String> participants = [];
  List<WinnerData> winners = [];
  
  String eventTitle = "LAIRE GRAND PRIZE";
  Color backgroundColor = const Color(0xFF0F172A); // Dark navy blue broadcast style
  String? backgroundBase64;
  
  bool isSpinning = false;
  String? rollingText; // Teks yang bergulir cepat
  String? finalWinner;
  
  final AudioPlayer audioPlayer = AudioPlayer();

  ServerSocket? _serverSocket;
  final List<Socket> _clients = [];
  Socket? _clientSocket;
  String _socketBuffer = '';
  Timer? _rollTimer;

  void setMode(AppMode mode) {
    currentMode = mode;
    notifyListeners();
    if (mode == AppMode.operator) {
      _startServer();
    } else if (mode == AppMode.display) {
      _connectToServer();
    }
  }

  // ================= IMPORT SPREADSHEET (OPTIMASI 10.000+ DATA) =================
  void importFromSpreadsheet(String text) {
    List<String> rawLines = text.split('\n');
    
    // Menggunakan SET agar proses 10.000 data terjadi instan (0.1 detik) anti-lag
    // Set juga otomatis mengabaikan data duplikat/ganda.
    Set<String> uniqueParticipants = participants.toSet(); 
    
    for (String line in rawLines) {
      String cleanLine = line.trim();
      if (cleanLine.isNotEmpty) {
        uniqueParticipants.add(cleanLine);
      }
    }
    
    participants = uniqueParticipants.toList();
    _broadcastState();
    notifyListeners();
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
      'title': eventTitle,
      'participants': participants,
      'winners': winners.map((w) => w.toJson()).toList(),
      'bgColor': backgroundColor.value,
      'bgBase64': backgroundBase64,
    };
    final jsonStr = jsonEncode(stateData) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

  // PERBAIKAN BUG UTAMA: Menentukan secara eksplisit tipe data Map<String, dynamic>
  void _broadcastCommand(String type, [Map<String, dynamic>? extra]) {
    if (_clients.isEmpty) return;
    final Map<String, dynamic> data = {'type': type}; 
    if (extra != null) data.addAll(extra);
    final jsonStr = jsonEncode(data) + '\n';
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
      }, onDone: () => Future.delayed(const Duration(seconds: 2), _connectToServer));
    } catch (e) {
      Future.delayed(const Duration(seconds: 2), _connectToServer);
    }
  }

  void _processCommand(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      switch (decoded['type']) {
        case 'sync':
          eventTitle = decoded['title'];
          participants = List<String>.from(decoded['participants']);
          winners = (decoded['winners'] as List).map((w) => WinnerData.fromJson(w)).toList();
          backgroundColor = Color(decoded['bgColor']);
          backgroundBase64 = decoded['bgBase64'];
          notifyListeners();
          break;
        case 'start_roll':
          _startRollingEffect();
          break;
        case 'stop_roll':
          _stopRollingEffect(decoded['winner']);
          break;
        case 'clear_popup':
          finalWinner = null;
          notifyListeners();
          break;
      }
    } catch (e) {
      debugPrint("Error parsing JSON: $e");
    }
  }

  // ================= KONTROL VISUAL & PESERTA =================
  void updateTitle(String newTitle) {
    eventTitle = newTitle;
    _broadcastState();
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    backgroundColor = color;
    backgroundBase64 = null;
    _broadcastState();
    notifyListeners();
  }

  Future<void> pickBackgroundImage() async {
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

  void removeParticipant(int index) {
    participants.removeAt(index);
    _broadcastState();
    notifyListeners();
  }
  
  void clearParticipants() {
    participants.clear();
    _broadcastState();
    notifyListeners();
  }

  // ================= KONTROL PEMENANG (SAH / HANGUS) =================
  void setWinnerStatus(int index, String status) {
    winners[index].status = status;
    _broadcastState();
    notifyListeners();
  }

  void clearWinnerPopup() {
    finalWinner = null;
    _broadcastCommand('clear_popup');
    notifyListeners();
  }

  // ================= LOGIKA UNDIAN (RAFFLE) =================
  void startRaffle() async {
    if (isSpinning || participants.isEmpty) return;
    
    // Mulai animasi
    _broadcastCommand('start_roll');
    _startRollingEffect(); 

    try {
      await audioPlayer.play(AssetSource('spin_sound.mp3'));
    } catch (e) {
      debugPrint("Suara tidak ditemukan");
    }

    // Tunggu 4 detik, lalu tentukan pemenang
    Future.delayed(const Duration(seconds: 4), () {
      int winningIndex = Random().nextInt(participants.length);
      String won = participants[winningIndex];
      
      participants.removeAt(winningIndex);
      winners.insert(0, WinnerData(name: won)); 
      
      _broadcastCommand('stop_roll', {'winner': won});
      _stopRollingEffect(won);
      
      Future.delayed(const Duration(milliseconds: 500), _broadcastState);
    });
  }

  void _startRollingEffect() {
    isSpinning = true;
    finalWinner = null;
    _rollTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (participants.isNotEmpty) {
        rollingText = participants[Random().nextInt(participants.length)];
        notifyListeners();
      }
    });
  }

  void _stopRollingEffect(String winner) {
    _rollTimer?.cancel();
    isSpinning = false;
    rollingText = null;
    finalWinner = winner;
    notifyListeners();
  }
}

class LaireRaffleApp extends StatelessWidget {
  const LaireRaffleApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laire Broadcast Raffle',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark, 
        fontFamily: 'Roboto', 
        scaffoldBackgroundColor: const Color(0xFF0F172A)
      ),
      home: Consumer<AppState>(
        builder: (context, state, child) {
          if (state.currentMode == AppMode.selection) return const ModeSelectionScreen();
          if (state.currentMode == AppMode.operator) return const OperatorScreen();
          return const Scaffold(body: RaffleDisplayView(isPreview: false));
        },
      ),
    );
  }
}

// ================= LAYAR PEMILIHAN =================
class ModeSelectionScreen extends StatelessWidget {
  const ModeSelectionScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context, listen: false);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              decoration: BoxDecoration(
                color: Colors.black, borderRadius: BorderRadius.circular(50),
                border: Border.all(color: Colors.amberAccent, width: 2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/Preview-4.png', height: 40, errorBuilder: (_,__,___) => const Icon(Icons.star, color: Colors.amber)),
                  const SizedBox(width: 15),
                  const Text("LAIRE CREATIVE STUDIO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 3.0, fontSize: 18)),
                ],
              ),
            ),
            const SizedBox(height: 60),
            ElevatedButton.icon(
              icon: const Icon(Icons.settings, size: 28),
              label: const Text("BUKA SEBAGAI OPERATOR", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20)),
              onPressed: () => state.setMode(AppMode.operator),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.monitor, size: 28),
              label: const Text("BUKA SEBAGAI DISPLAY PROYEKTOR", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20), side: const BorderSide(color: Colors.amber, width: 2)),
              onPressed: () => state.setMode(AppMode.display),
            ),
          ],
        ),
      ),
    );
  }
}

// ================= LAYAR OPERATOR =================
class OperatorScreen extends StatelessWidget {
  const OperatorScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final TextEditingController importController = TextEditingController();

    return Scaffold(
      appBar: AppBar(
        title: const Text('LAIRE BROADCAST KONTROL', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
        backgroundColor: Colors.black,
      ),
      body: Row(
        children: [
          // KOLOM 1: PENGATURAN & IMPORT
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white12))),
              child: ListView(
                children: [
                  const Text("IMPORT DARI SPREADSHEET (10.000+ DATA)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: importController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText: "Copy data dari Excel lalu Paste di sini...\n(Otomatis menghapus data yang kembar/double)",
                      border: OutlineInputBorder(), filled: true, fillColor: Colors.black45,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                    onPressed: () {
                      state.importFromSpreadsheet(importController.text);
                      importController.clear();
                      FocusScope.of(context).unfocus();
                    },
                    child: const Text("IMPORT DATA SEKARANG", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 30),
                  
                  const Text("KUSTOMISASI VISUAL", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  TextField(
                    decoration: InputDecoration(labelText: 'Judul Event', hintText: state.eventTitle),
                    onSubmitted: (val) => state.updateTitle(val),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: OutlinedButton(onPressed: () => _showColorPicker(context, state), child: const Text('Warna', style: TextStyle(fontSize: 12)))),
                      const SizedBox(width: 5),
                      Expanded(child: OutlinedButton(onPressed: () => state.pickBackgroundImage(), child: const Text('Gambar', style: TextStyle(fontSize: 12)))),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Tutup Popup Pemenang'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: () => state.clearWinnerPopup(),
                  ),
                ],
              ),
            ),
          ),
          
          // KOLOM 2: LIVE PREVIEW & TOMBOL UNDI
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text("LIVE PREVIEW", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.white54)),
                  const SizedBox(height: 15),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.amber, width: 2), borderRadius: BorderRadius.circular(10)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: const RaffleDisplayView(isPreview: true),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity, height: 70,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 40),
                      label: Text(state.isSpinning ? 'MENGACAK...' : 'ACAK PEMENANG SEKARANG', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: state.isSpinning ? Colors.grey : Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: (state.isSpinning || state.participants.isEmpty) ? null : () => state.startRaffle(),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // KOLOM 3: DAFTAR DATA & STATUS
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(border: Border(left: BorderSide(color: Colors.white12))),
              child: Column(
                children: [
                  // DATA PESERTA
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("DATA MASUK", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                      Text("${state.participants.length}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    flex: 1,
                    child: ListView.builder(
                      itemCount: state.participants.length,
                      itemBuilder: (context, i) => ListTile(
                        dense: true,
                        title: Text(state.participants[i], style: const TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold)),
                        trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 16), onPressed: () => state.removeParticipant(i)),
                      ),
                    ),
                  ),
                  TextButton(onPressed: () => state.clearParticipants(), child: const Text("Hapus Semua Data Peserta", style: TextStyle(color: Colors.redAccent))),
                  
                  const SizedBox(height: 20),
                  
                  // DATA PEMENANG & VERIFIKASI
                  const Text("HASIL UNDIAN (VERIFIKASI)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                  const Divider(),
                  Expanded(
                    flex: 2,
                    child: ListView.builder(
                      itemCount: state.winners.length,
                      itemBuilder: (context, i) {
                        final w = state.winners[i];
                        bool isHangus = w.status == 'HANGUS';
                        bool isSah = w.status == 'SAH';
                        
                        return Card(
                          color: isHangus ? Colors.red.withOpacity(0.2) : (isSah ? Colors.green.withOpacity(0.2) : Colors.white10),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(w.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, decoration: isHangus ? TextDecoration.lineThrough : null, color: isHangus ? Colors.redAccent : Colors.white)),
                                const SizedBox(height: 5),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (!isSah)
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero),
                                        onPressed: () => state.setWinnerStatus(i, 'SAH'),
                                        child: const Text("✅ SAH"),
                                      ),
                                    const SizedBox(width: 5),
                                    if (!isHangus)
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero),
                                        onPressed: () => state.setWinnerStatus(i, 'HANGUS'),
                                        child: const Text("❌ HANGUS"),
                                      ),
                                  ],
                                )
                              ],
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
        content: SingleChildScrollView(child: ColorPicker(pickerColor: state.backgroundColor, onColorChanged: (color) => state.updateBackgroundColor(color))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai'))],
      ),
    );
  }
}

// ================= KOMPONEN RAFFLE DISPLAY UTAMA =================
class RaffleDisplayView extends StatelessWidget {
  final bool isPreview;
  const RaffleDisplayView({Key? key, required this.isPreview}) : super(key: key);

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
          // JUDUL & NOMOR BERGULIR
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  state.eventTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isPreview ? 20 : 50, 
                    fontWeight: FontWeight.w900, 
                    color: Colors.amber, 
                    letterSpacing: 4.0, 
                    shadows: const [Shadow(color: Colors.black, blurRadius: 20, offset: Offset(0, 5))]
                  ),
                ),
                SizedBox(height: isPreview ? 20 : 60),
                
                // BOX RAFFLE
                Container(
                  width: isPreview ? 250 : 700,
                  height: isPreview ? 80 : 200,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: state.isSpinning ? Colors.amber : Colors.white24, width: state.isSpinning ? 4 : 2),
                    boxShadow: state.isSpinning ? [BoxShadow(color: Colors.amber.withOpacity(0.5), blurRadius: 30, spreadRadius: 5)] : [],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    state.rollingText ?? (state.participants.isEmpty ? "READY" : "STANDBY"),
                    style: TextStyle(
                      fontFamily: 'Courier', 
                      fontSize: isPreview ? 35 : 100,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 5.0,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // OVERLAY DAFTAR PEMENANG (KANAN BAWAH)
          if (!isPreview && state.winners.isNotEmpty)
            Positioned(
              right: 40, bottom: 120,
              child: Container(
                width: 350,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.amber, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("DAFTAR PEMENANG", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 2)),
                    const Divider(color: Colors.white24),
                    ...state.winners.take(5).map((w) {
                      bool isHangus = w.status == 'HANGUS';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              w.name, 
                              style: TextStyle(
                                fontFamily: 'Courier', 
                                color: isHangus ? Colors.redAccent : Colors.white, 
                                fontWeight: FontWeight.bold, 
                                fontSize: 24,
                                decoration: isHangus ? TextDecoration.lineThrough : null
                              )
                            ),
                            if (isHangus)
                              const Text("HANGUS", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 16))
                            else if (w.status == 'SAH')
                              const Icon(Icons.check_circle, color: Colors.green)
                          ],
                        ),
                      );
                    }).toList(),
                    if (state.winners.length > 5)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text("...dan lainnya", style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
                      )
                  ],
                ),
              ),
            ),

          // LOGO LAIRE CREATIVE STUDIO (SOLID PILL - BAWAH TENGAH)
          Positioned(
            bottom: isPreview ? 15 : 40, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: isPreview ? 20 : 40, vertical: isPreview ? 8 : 15),
                decoration: BoxDecoration(
                  color: Colors.black, // Background hitam pekat (Solid)
                  borderRadius: BorderRadius.circular(50), 
                  border: Border.all(color: Colors.amber, width: isPreview ? 1 : 2), // Border emas solid
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 15, spreadRadius: 5)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/Preview-4.png', height: isPreview ? 20 : 45, errorBuilder: (_,__,___) => const Icon(Icons.star, color: Colors.amber)),
                    SizedBox(width: isPreview ? 10 : 20),
                    Text(
                      "LAIRE CREATIVE STUDIO",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: isPreview ? 1.5 : 4.0,
                        fontSize: isPreview ? 12 : 22,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // POPUP ANIMASI ZOOM IN PEMENANG (TENGAH LAYAR)
          if (state.finalWinner != null)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.9),
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.1, end: 1.0),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.elasticOut,
                    builder: (context, scale, child) {
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: isPreview ? 40 : 100, vertical: isPreview ? 30 : 60),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0xFFD4AF37), Color(0xFFF3E5AB)]),
                            borderRadius: BorderRadius.circular(isPreview ? 15 : 30),
                            border: Border.all(color: Colors.white, width: isPreview ? 3 : 8),
                            boxShadow: [BoxShadow(color: Colors.amber.withOpacity(0.4), blurRadius: 100, spreadRadius: 30)],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("🎉 SELAMAT 🎉", style: TextStyle(fontSize: isPreview ? 16 : 30, fontWeight: FontWeight.bold, color: Colors.black87, letterSpacing: 5)),
                              SizedBox(height: isPreview ? 10 : 20),
                              Text(
                                state.finalWinner!.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: isPreview ? 45 : 120, 
                                  fontWeight: FontWeight.w900, 
                                  color: Colors.black, 
                                  shadows: const [Shadow(color: Colors.white, offset: Offset(2, 2), blurRadius: 0)]
                                ),
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
