import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    center: true,
    title: "Laire Broadcast Raffle",
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

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
  String status; 
  WinnerData({required this.name, this.status = 'MENUNGGU'});
  Map<String, dynamic> toJson() => {'name': name, 'status': status};
  factory WinnerData.fromJson(Map<String, dynamic> json) => WinnerData(name: json['name'], status: json['status']);
}

class AppState extends ChangeNotifier {
  AppMode currentMode = AppMode.selection;
  
  List<String> participants = [];
  List<WinnerData> winners = [];
  
  String eventTitle = "LAIRE GRAND PRIZE";
  Color backgroundColor = const Color(0xFF0F172A); 
  Color boxColor = const Color(0xDD000000); // Warna default box angka
  String? backgroundBase64;
  bool showWinnerList = false; // Default disembunyikan agar bersih
  
  bool isSpinning = false;
  String? rollingText; 
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

  // ================= OPTIMASI IMPORT (ANTI-LAG) =================
  void importFromSpreadsheet(String text) {
    List<String> rawLines = text.split('\n');
    Set<String> uniqueParticipants = participants.toSet(); 
    for (String line in rawLines) {
      String cleanLine = line.trim();
      if (cleanLine.isNotEmpty) uniqueParticipants.add(cleanLine);
    }
    participants = uniqueParticipants.toList();
    _broadcastParticipants(); // HANYA kirim data peserta, tidak kirim gambar/warna
    notifyListeners();
  }

  // ================= SERVER (OPERATOR) =================
  void _startServer() async {
    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 8765);
      _serverSocket!.listen((Socket client) {
        _clients.add(client);
        _broadcastFullState(); // Kirim semua data ke client baru
        client.listen((data) {}, onDone: () => _clients.remove(client));
      });
    } catch (e) {
      debugPrint("Gagal membuat server: $e");
    }
  }

  // Pecah fungsi broadcast agar 5000 data tidak dikirim terus-menerus
  void _broadcastFullState() {
    _broadcastConfig();
    _broadcastParticipants();
    _broadcastWinners();
  }

  void _broadcastConfig() {
    _broadcastCommand('sync_config', {
      'title': eventTitle,
      'bgColor': backgroundColor.value,
      'boxColor': boxColor.value,
      'bgBase64': backgroundBase64,
      'showWinnerList': showWinnerList,
    });
  }

  void _broadcastParticipants() {
    _broadcastCommand('sync_participants', {'participants': participants});
  }

  void _broadcastWinners() {
    _broadcastCommand('sync_winners', {'winners': winners.map((w) => w.toJson()).toList()});
  }

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
        _socketBuffer += utf8.decode(data, allowMalformed: true);
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

  void _processCommand(String jsonStr) async {
    try {
      final decoded = jsonDecode(jsonStr);
      switch (decoded['type']) {
        case 'sync_config':
          eventTitle = decoded['title'];
          backgroundColor = Color(decoded['bgColor']);
          boxColor = Color(decoded['boxColor']);
          backgroundBase64 = decoded['bgBase64'];
          showWinnerList = decoded['showWinnerList'];
          notifyListeners();
          break;
        case 'sync_participants':
          participants = List<String>.from(decoded['participants']);
          notifyListeners();
          break;
        case 'sync_winners':
          winners = (decoded['winners'] as List).map((w) => WinnerData.fromJson(w)).toList();
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
        case 'force_fullscreen':
          // Remote Fullscreen untuk layar 2
          bool isFull = await windowManager.isFullScreen();
          await windowManager.setFullScreen(!isFull);
          break;
      }
    } catch (e) {
      debugPrint("Error parsing JSON: $e");
    }
  }

  // ================= KONTROL VISUAL & PESERTA =================
  void triggerRemoteFullscreen() {
    _broadcastCommand('force_fullscreen');
  }

  void toggleWinnerList() {
    showWinnerList = !showWinnerList;
    _broadcastConfig();
    notifyListeners();
  }

  void updateTitle(String newTitle) {
    eventTitle = newTitle;
    _broadcastConfig();
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    backgroundColor = color;
    backgroundBase64 = null;
    _broadcastConfig();
    notifyListeners();
  }

  void updateBoxColor(Color color) {
    boxColor = color;
    _broadcastConfig();
    notifyListeners();
  }

  Future<void> pickBackgroundImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result != null) {
      Uint8List? fileBytes = result.files.single.bytes ?? await File(result.files.single.path!).readAsBytes();
      backgroundBase64 = base64Encode(fileBytes);
      _broadcastConfig();
      notifyListeners();
    }
  }

  void removeParticipant(int index) {
    participants.removeAt(index);
    _broadcastParticipants();
    notifyListeners();
  }
  
  void clearParticipants() {
    participants.clear();
    _broadcastParticipants();
    notifyListeners();
  }

  // ================= KONTROL PEMENANG =================
  void setWinnerStatus(int index, String status) {
    winners[index].status = status;
    _broadcastWinners();
    notifyListeners();
  }

  void clearWinnerPopup() {
    finalWinner = null;
    _broadcastCommand('clear_popup');
    notifyListeners();
  }

  void resetAllWinners() {
    winners.clear();
    _broadcastWinners();
    notifyListeners();
  }

  // ================= LOGIKA UNDIAN (RAFFLE) =================
  void startRaffle() async {
    if (isSpinning || participants.isEmpty) return;
    
    _broadcastCommand('start_roll');
    _startRollingEffect(); 

    try {
      await audioPlayer.play(AssetSource('spin_sound.mp3'));
    } catch (e) {}

    Future.delayed(const Duration(seconds: 4), () {
      int winningIndex = Random().nextInt(participants.length);
      String won = participants[winningIndex];
      
      participants.removeAt(winningIndex);
      winners.insert(0, WinnerData(name: won)); 
      
      _broadcastCommand('stop_roll', {'winner': won});
      _stopRollingEffect(won);
      
      Future.delayed(const Duration(milliseconds: 500), () {
        _broadcastParticipants();
        _broadcastWinners();
      });
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
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto', scaffoldBackgroundColor: const Color(0xFF0F172A)),
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
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(50), border: Border.all(color: Colors.amberAccent, width: 2)),
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
      appBar: AppBar(title: const Text('LAIRE BROADCAST KONTROL', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)), backgroundColor: Colors.black),
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
                  const Text("KONTROL LAYAR PROYEKTOR", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.fullscreen),
                    label: const Text('Jadikan Fullscreen (Layar 2)'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, padding: const EdgeInsets.all(12)),
                    onPressed: () => state.triggerRemoteFullscreen(),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    title: const Text("Tampilkan Box Pemenang"),
                    subtitle: const Text("Muncul di sisi kanan layar"),
                    activeColor: Colors.amber,
                    contentPadding: EdgeInsets.zero,
                    value: state.showWinnerList,
                    onChanged: (val) => state.toggleWinnerList(),
                  ),
                  const SizedBox(height: 15),

                  const Text("KUSTOMISASI VISUAL", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  TextField(decoration: InputDecoration(labelText: 'Judul Event', hintText: state.eventTitle), onSubmitted: (val) => state.updateTitle(val)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(icon: const Icon(Icons.image), label: const Text('Ganti Gambar Background'), onPressed: () => state.pickBackgroundImage()),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(child: OutlinedButton(onPressed: () => _showColorPicker(context, state, true), child: const Text('Warna Background'))),
                      const SizedBox(width: 5),
                      Expanded(child: OutlinedButton(onPressed: () => _showColorPicker(context, state, false), child: const Text('Warna Box Angka'))),
                    ],
                  ),
                  const SizedBox(height: 25),

                  const Text("IMPORT DATA (10.000+ Anti Lag)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  TextField(controller: importController, maxLines: 5, decoration: const InputDecoration(hintText: "Paste data Excel di sini...", border: OutlineInputBorder(), filled: true, fillColor: Colors.black45)),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: () { state.importFromSpreadsheet(importController.text); importController.clear(); FocusScope.of(context).unfocus(); },
                    child: const Text("IMPORT", style: TextStyle(fontWeight: FontWeight.bold)),
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
                  const SizedBox(height: 10),
                  Expanded(
                    child: Center(
                      // Memaksa rasio 16:9 agar sama persis dengan layar proyektor
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Container(
                          decoration: BoxDecoration(border: Border.all(color: Colors.amber, width: 2)),
                          child: const ClipRect(child: RaffleDisplayView(isPreview: true)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: SizedBox(
                          height: 70,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.play_arrow, size: 40),
                            label: Text(state.isSpinning ? 'MENGACAK...' : 'ACAK SEKARANG', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                            style: ElevatedButton.styleFrom(backgroundColor: state.isSpinning ? Colors.grey : Colors.green, foregroundColor: Colors.white),
                            onPressed: (state.isSpinning || state.participants.isEmpty) ? null : () => state.startRaffle(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: SizedBox(
                          height: 70,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.close), label: const Text("Tutup\nPopup"),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: () => state.clearWinnerPopup(),
                          ),
                        ),
                      ),
                    ],
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
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("DATA MASUK", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)), Text("${state.participants.length}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))]),
                  const Divider(),
                  Expanded(
                    flex: 1,
                    child: ListView.builder(
                      itemCount: state.participants.length,
                      itemBuilder: (context, i) => ListTile(dense: true, title: Text(state.participants[i], style: const TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold)), trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 16), onPressed: () => state.removeParticipant(i))),
                    ),
                  ),
                  TextButton(onPressed: () => state.clearParticipants(), child: const Text("Hapus Semua Data Peserta", style: TextStyle(color: Colors.redAccent))),
                  const SizedBox(height: 10),
                  
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("HASIL UNDIAN", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)), Text("${state.winners.length}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))]),
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
                                    if (!isSah) ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero), onPressed: () => state.setWinnerStatus(i, 'SAH'), child: const Text("✅ SAH")),
                                    const SizedBox(width: 5),
                                    if (!isHangus) ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero), onPressed: () => state.setWinnerStatus(i, 'HANGUS'), child: const Text("❌ HANGUS")),
                                  ],
                                )
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () => state.resetAllWinners(), child: const Text("RESET DATA PEMENANG", style: TextStyle(fontWeight: FontWeight.bold)))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(BuildContext context, AppState state, bool isBackground) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isBackground ? 'Warna Background' : 'Warna Box Angka'),
        content: SingleChildScrollView(
          // Memastikan ada Eyedropper dan input Hex
          child: ColorPicker(
            pickerColor: isBackground ? state.backgroundColor : state.boxColor, 
            onColorChanged: (color) {
              if (isBackground) {
                state.updateBackgroundColor(color);
              } else {
                state.updateBoxColor(color);
              }
            },
            enableAlpha: true,
            displayThumbColor: true,
            hexInputBar: true,
          )
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
      ),
    );
  }
}

// ================= KOMPONEN RAFFLE DISPLAY UTAMA DENGAN SHAKE EFFECT =================
class RaffleDisplayView extends StatefulWidget {
  final bool isPreview;
  const RaffleDisplayView({Key? key, required this.isPreview}) : super(key: key);

  @override
  State<RaffleDisplayView> createState() => _RaffleDisplayViewState();
}

class _RaffleDisplayViewState extends State<RaffleDisplayView> with SingleTickerProviderStateMixin {
  late AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    // Animasi getar cepat
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 50));
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    if (state.isSpinning) {
      _shakeController.repeat(reverse: true);
    } else {
      _shakeController.stop();
      _shakeController.reset();
    }

    Widget content = Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: state.backgroundColor,
        image: state.backgroundBase64 != null ? DecorationImage(image: MemoryImage(base64Decode(state.backgroundBase64!)), fit: BoxFit.cover) : null,
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
                  style: TextStyle(fontSize: widget.isPreview ? 20 : 60, fontWeight: FontWeight.w900, color: Colors.amber, letterSpacing: 4.0, shadows: const [Shadow(color: Colors.black, blurRadius: 20, offset: Offset(0, 5))]),
                ),
                SizedBox(height: widget.isPreview ? 20 : 60),
                
                // BOX RAFFLE (BISA DIGANTI WARNANYA)
                Container(
                  width: widget.isPreview ? 250 : 800,
                  height: widget.isPreview ? 80 : 250,
                  decoration: BoxDecoration(
                    color: state.boxColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: state.isSpinning ? Colors.amber : Colors.white24, width: state.isSpinning ? 4 : 2),
                    boxShadow: state.isSpinning ? [BoxShadow(color: Colors.amber.withOpacity(0.5), blurRadius: 30, spreadRadius: 5)] : [],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    state.rollingText ?? (state.participants.isEmpty ? "READY" : "STANDBY"),
                    style: TextStyle(fontFamily: 'Courier', fontSize: widget.isPreview ? 35 : 120, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 5.0),
                  ),
                ),
              ],
            ),
          ),

          // OVERLAY DAFTAR PEMENANG (HANYA MUNCUL JIKA DINYALAKAN DARI OPERATOR)
          if (!widget.isPreview && state.showWinnerList && state.winners.isNotEmpty)
            Positioned(
              right: 50, bottom: 150,
              child: Container(
                width: 350, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.amber, width: 2)),
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
                            Text(w.name, style: TextStyle(fontFamily: 'Courier', color: isHangus ? Colors.redAccent : Colors.white, fontWeight: FontWeight.bold, fontSize: 24, decoration: isHangus ? TextDecoration.lineThrough : null)),
                            if (isHangus) const Text("HANGUS", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 16))
                            else if (w.status == 'SAH') const Icon(Icons.check_circle, color: Colors.green)
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),

          // LOGO LAIRE CREATIVE STUDIO (UKURAN DIPERKECIL & DIGESER KE BAWAH)
          Positioned(
            bottom: widget.isPreview ? 5 : 20, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: widget.isPreview ? 15 : 30, vertical: widget.isPreview ? 5 : 10),
                decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(50), border: Border.all(color: Colors.amber, width: 1), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10, spreadRadius: 2)]),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/Preview-4.png', height: widget.isPreview ? 12 : 25, errorBuilder: (_,__,___) => const Icon(Icons.star, color: Colors.amber)),
                    SizedBox(width: widget.isPreview ? 8 : 15),
                    Text("LAIRE CREATIVE STUDIO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 2.0, fontSize: widget.isPreview ? 8 : 16)),
                  ],
                ),
              ),
            ),
          ),

          // POPUP ANIMASI ZOOM IN PEMENANG
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
                          padding: EdgeInsets.symmetric(horizontal: widget.isPreview ? 40 : 100, vertical: widget.isPreview ? 30 : 60),
                          decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFD4AF37), Color(0xFFF3E5AB)]), borderRadius: BorderRadius.circular(widget.isPreview ? 15 : 30), border: Border.all(color: Colors.white, width: widget.isPreview ? 3 : 8), boxShadow: [BoxShadow(color: Colors.amber.withOpacity(0.4), blurRadius: 100, spreadRadius: 30)]),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("🎉 SELAMAT 🎉", style: TextStyle(fontSize: widget.isPreview ? 16 : 30, fontWeight: FontWeight.bold, color: Colors.black87, letterSpacing: 5)),
                              SizedBox(height: widget.isPreview ? 10 : 20),
                              Text(state.finalWinner!.toUpperCase(), textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Courier', fontSize: widget.isPreview ? 45 : 120, fontWeight: FontWeight.w900, color: Colors.black, shadows: const [Shadow(color: Colors.white, offset: Offset(2, 2), blurRadius: 0)])),
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

    // BUNGKUS DENGAN ANIMATED BUILDER UNTUK EFEK GETAR (SHAKE)
    return AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(sin(_shakeController.value * pi * 4) * (widget.isPreview ? 2 : 5), cos(_shakeController.value * pi * 4) * (widget.isPreview ? 2 : 5)),
          child: child,
        );
      },
      child: content,
    );
  }
}
