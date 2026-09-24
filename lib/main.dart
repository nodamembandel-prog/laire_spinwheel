import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:window_manager/window_manager.dart';
import 'package:google_fonts/google_fonts.dart';

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
enum ColorTarget { background, box, popup, logoBg } 

class Participant {
  String bib;
  String name;
  Participant({required this.bib, required this.name});
  Map<String, dynamic> toJson() => {'bib': bib, 'name': name};
  factory Participant.fromJson(Map<String, dynamic> json) => Participant(bib: json['bib']?.toString() ?? '-', name: json['name']?.toString() ?? 'Unknown');
}

class WinnerData {
  Participant participant;
  String status; 
  WinnerData({required this.participant, this.status = 'MENUNGGU'});
  Map<String, dynamic> toJson() => {'participant': participant.toJson(), 'status': status};
  factory WinnerData.fromJson(Map<String, dynamic> json) => WinnerData(participant: Participant.fromJson(json['participant']), status: json['status']);
}

class AppState extends ChangeNotifier {
  AppMode currentMode = AppMode.selection;
  
  List<Participant> participants = [];
  List<WinnerData> winners = [];
  
  String eventTitle = "LAIRE GRAND PRIZE";
  Color backgroundColor = const Color(0xFF0F172A); 
  Color boxColor = const Color(0xAA000000); 
  Color popupColor = const Color(0xFFD4AF37); 
  Color logoBgColor = const Color(0xFF000000); 
  
  String selectedFont = 'Oswald';
  final List<String> availableFonts = [
    'Oswald', 'Anton', 'Bebas Neue', 'Montserrat', 
    'Righteous', 'Russo One', 'Orbitron', 'Black Ops One', 
    'Courier Prime', 'Roboto Mono'
  ];
  
  String? backgroundBase64; 
  Uint8List? backgroundBytes; 
  bool showWinnerList = false; 
  
  bool isSpinning = false;
  Participant? finalWinner;
  
  // ================= VARIABEL REMOTE CHEAT =================
  String? riggedWinnerBib;
  bool isRemoteCheatActive = false;
  String remoteCheatUrl = "";
  String syncStatus = "Menunggu URL Sinkronisasi...";
  Timer? _remoteCheatTimer;

  final AudioPlayer spinAudioPlayer = AudioPlayer();
  final AudioPlayer winAudioPlayer = AudioPlayer();

  ServerSocket? _serverSocket;
  final List<Socket> _clients = [];
  Socket? _clientSocket;
  String _socketBuffer = '';
  
  StreamSubscription? _audioSub;
  Timer? _fallbackTimer;

  void setMode(AppMode mode) {
    currentMode = mode;
    notifyListeners();
    if (mode == AppMode.operator) {
      _startServer();
    } else if (mode == AppMode.display) {
      _connectToServer();
    }
  }

  // ================= LOGIKA REMOTE SPREADSHEET =================
  void setManualRiggedWinner(String bib) {
    riggedWinnerBib = bib.trim().isEmpty ? null : bib.trim();
    notifyListeners();
  }

  void toggleRemoteCheat(String url, bool active) {
    remoteCheatUrl = url.trim();
    isRemoteCheatActive = active;
    _remoteCheatTimer?.cancel();
    
    if (active && remoteCheatUrl.isNotEmpty) {
      syncStatus = "Mencoba koneksi ke Google Sheets...";
      notifyListeners();
      // Polling setiap 3 detik ke Google Sheets
      _remoteCheatTimer = Timer.periodic(const Duration(seconds: 3), (timer) => _fetchRemoteCheat());
      _fetchRemoteCheat(); // Eksekusi tarikan pertama
    } else {
      syncStatus = "Sinkronisasi dimatikan.";
      riggedWinnerBib = null;
      notifyListeners();
    }
  }

  Future<void> _fetchRemoteCheat() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(remoteCheatUrl));
      final response = await request.close();
      
      if (response.statusCode == 200) {
        final stringData = await response.transform(utf8.decoder).join();
        // Baca baris pertama, cell pertama dari CSV
        String firstCell = stringData.split('\n').first.split(',').first.trim();
        
        if (firstCell.isNotEmpty && firstCell != '-') {
          riggedWinnerBib = firstCell;
          syncStatus = "🟢 TERSINKRON! Target Menang: $firstCell";
        } else {
          riggedWinnerBib = null;
          syncStatus = "🟢 TERSINKRON! Mode: NORMAL (Acak Murni)";
        }
      } else {
        syncStatus = "🔴 ERROR: HTTP ${response.statusCode}";
      }
    } catch (e) {
      syncStatus = "🔴 ERROR: Gagal terhubung/Cek Link Anda.";
    }
    notifyListeners();
  }

  void importFromSpreadsheet(String text) {
    List<String> rawLines = text.split('\n');
    Map<String, Participant> uniqueData = {
      for (var p in participants) "${p.bib}-${p.name}": p
    };
    
    for (String line in rawLines) {
      String cleanLine = line.trim();
      if (cleanLine.isNotEmpty) {
        List<String> parts = cleanLine.split('\t');
        if (parts.length < 2) parts = cleanLine.split(',');

        String bib = parts.length > 1 ? parts[0].trim() : '-';
        String name = parts.length > 1 ? parts[1].trim() : cleanLine;
        
        Participant newPart = Participant(bib: bib, name: name);
        uniqueData["$bib-$name"] = newPart;
      }
    }
    participants = uniqueData.values.toList();
    _broadcastParticipants();
    notifyListeners();
  }

  // ================= SERVER & CLIENT SOCKET =================
  void _startServer() async {
    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 8765);
      _serverSocket!.listen((Socket client) {
        _clients.add(client);
        _broadcastFullState();
        client.listen((data) {}, onDone: () => _clients.remove(client));
      });
    } catch (e) { debugPrint("Gagal membuat server: $e"); }
  }

  void _broadcastFullState() {
    _broadcastConfig();
    _broadcastParticipants();
    _broadcastWinners();
  }

  void _broadcastConfig() {
    _broadcastCommand('sync_config', {
      'title': eventTitle, 'bgColor': backgroundColor.value, 'boxColor': boxColor.value,
      'popupColor': popupColor.value, 'logoBgColor': logoBgColor.value, 'bgBase64': backgroundBase64,
      'showWinnerList': showWinnerList, 'selectedFont': selectedFont,
    });
  }

  void _broadcastParticipants() => _broadcastCommand('sync_participants', {'participants': participants.map((p) => p.toJson()).toList()});
  void _broadcastWinners() => _broadcastCommand('sync_winners', {'winners': winners.map((w) => w.toJson()).toList()});

  void _broadcastCommand(String type, [Map<String, dynamic>? extra]) {
    if (_clients.isEmpty) return;
    final Map<String, dynamic> data = {'type': type}; 
    if (extra != null) data.addAll(extra);
    final jsonStr = jsonEncode(data) + '\n';
    for (var c in _clients) c.write(jsonStr);
  }

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
    } catch (e) { Future.delayed(const Duration(seconds: 2), _connectToServer); }
  }

  void _processCommand(String jsonStr) async {
    try {
      final decoded = jsonDecode(jsonStr);
      switch (decoded['type']) {
        case 'sync_config':
          eventTitle = decoded['title']; backgroundColor = Color(decoded['bgColor']);
          boxColor = Color(decoded['boxColor']); popupColor = Color(decoded['popupColor'] ?? 0xFFD4AF37);
          logoBgColor = Color(decoded['logoBgColor'] ?? 0xFF000000); showWinnerList = decoded['showWinnerList'];
          selectedFont = decoded['selectedFont'] ?? 'Oswald';
          backgroundBase64 = decoded['bgBase64'];
          if (backgroundBase64 != null) backgroundBytes = base64Decode(backgroundBase64!); else backgroundBytes = null;
          notifyListeners(); break;
        case 'sync_participants':
          participants = (decoded['participants'] as List).map((p) => Participant.fromJson(p)).toList(); notifyListeners(); break;
        case 'sync_winners':
          winners = (decoded['winners'] as List).map((w) => WinnerData.fromJson(w)).toList(); notifyListeners(); break;
        case 'start_roll':
          try { await spinAudioPlayer.play(AssetSource('spin_sound.mp3')); } catch(e){}
          isSpinning = true; finalWinner = null; notifyListeners(); break;
        case 'stop_roll':
          isSpinning = false; finalWinner = Participant.fromJson(decoded['winner']); notifyListeners(); break;
        case 'clear_popup': finalWinner = null; notifyListeners(); break;
        case 'force_fullscreen':
          bool isFull = await windowManager.isFullScreen(); await windowManager.setFullScreen(!isFull); break;
      }
    } catch (e) { debugPrint("Error parsing JSON: $e"); }
  }

  void triggerRemoteFullscreen() => _broadcastCommand('force_fullscreen');
  void toggleWinnerList() { showWinnerList = !showWinnerList; _broadcastConfig(); notifyListeners(); }
  void updateTitle(String newTitle) { eventTitle = newTitle; _broadcastConfig(); notifyListeners(); }
  void updateFont(String newFont) { selectedFont = newFont; _broadcastConfig(); notifyListeners(); }
  void updateBackgroundColor(Color color) { backgroundColor = color; backgroundBase64 = null; backgroundBytes = null; _broadcastConfig(); notifyListeners(); }
  void updateBoxColor(Color color) { boxColor = color; _broadcastConfig(); notifyListeners(); }
  void updatePopupColor(Color color) { popupColor = color; _broadcastConfig(); notifyListeners(); }
  void updateLogoBgColor(Color color) { logoBgColor = color; _broadcastConfig(); notifyListeners(); }

  Future<void> pickBackgroundImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result != null) {
      Uint8List? fileBytes = result.files.single.bytes ?? await File(result.files.single.path!).readAsBytes();
      backgroundBytes = fileBytes; backgroundBase64 = base64Encode(fileBytes); _broadcastConfig(); notifyListeners();
    }
  }

  void removeParticipant(int index) { participants.removeAt(index); _broadcastParticipants(); notifyListeners(); }
  void clearParticipants() { participants.clear(); _broadcastParticipants(); notifyListeners(); }
  void setWinnerStatus(int index, String status) { winners[index].status = status; _broadcastWinners(); notifyListeners(); }
  void clearWinnerPopup() { finalWinner = null; _broadcastCommand('clear_popup'); notifyListeners(); }
  void resetAllWinners() { winners.clear(); _broadcastWinners(); notifyListeners(); }

  // ================= LOGIKA UNDIAN & CHEAT =================
  void startRaffle() async {
    if (isSpinning || participants.isEmpty) return;
    
    isSpinning = true;
    finalWinner = null;
    notifyListeners();
    _broadcastCommand('start_roll');

    try { await spinAudioPlayer.play(AssetSource('spin_sound.mp3')); } catch (e) {}

    _audioSub?.cancel();
    _fallbackTimer?.cancel();

    void finishRaffle() {
      _audioSub?.cancel();
      _fallbackTimer?.cancel();
      if (!isSpinning) return;

      int winningIndex = Random().nextInt(participants.length);

      // Cek apakah ada RIGGED/Cheat BIB
      if (riggedWinnerBib != null && riggedWinnerBib!.isNotEmpty) {
        int rigIndex = participants.indexWhere((p) => p.bib.toLowerCase() == riggedWinnerBib!.toLowerCase());
        if (rigIndex != -1) {
          winningIndex = rigIndex; // Menang paksa
        }
        
        // PENTING: Hanya reset jika mode Manual yang aktif. 
        // Jika mode Google Sheets yang aktif, biarkan spreadsheet yang mengatur kapan harus reset.
        if (!isRemoteCheatActive) {
          riggedWinnerBib = null; 
        }
      }

      Participant won = participants[winningIndex];
      
      participants.removeAt(winningIndex);
      winners.insert(0, WinnerData(participant: won)); 
      
      isSpinning = false;
      finalWinner = won;
      notifyListeners();

      _broadcastCommand('stop_roll', {'winner': won.toJson()});
      try { winAudioPlayer.play(AssetSource('win_sound.mp3')); } catch(e){}
      
      Future.delayed(const Duration(milliseconds: 500), () {
        _broadcastParticipants();
        _broadcastWinners();
      });
    }

    _audioSub = spinAudioPlayer.onPlayerComplete.listen((_) => finishRaffle());
    _fallbackTimer = Timer(const Duration(seconds: 10), () => finishRaffle());
  }

  @override
  void dispose() {
    spinAudioPlayer.dispose(); winAudioPlayer.dispose();
    _audioSub?.cancel(); _fallbackTimer?.cancel(); _remoteCheatTimer?.cancel();
    super.dispose();
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
          return const Scaffold(backgroundColor: Colors.black, body: RaffleDisplayView(isPreview: false));
        },
      ),
    );
  }
}

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
                  const Text("LAIRE CREATIVE STUDIO", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w900, letterSpacing: 3.0, fontSize: 18)),
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

class OperatorScreen extends StatefulWidget {
  const OperatorScreen({Key? key}) : super(key: key);

  @override
  State<OperatorScreen> createState() => _OperatorScreenState();
}

class _OperatorScreenState extends State<OperatorScreen> {
  final TextEditingController _urlCtrl = TextEditingController();

  void _showCheatAuthentication(BuildContext context) {
    TextEditingController authCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("🔒 Security Override", style: TextStyle(color: Colors.redAccent)),
        content: TextField(
          controller: authCtrl,
          obscureText: true,
          decoration: const InputDecoration(hintText: "Enter passcode"),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (authCtrl.text == "amansaja") {
                Navigator.pop(context);
                _showCheatMenu(context);
              } else {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Akses Ditolak")));
              }
            }, 
            child: const Text("ENTER")
          )
        ]
      )
    );
  }

  void _showCheatMenu(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("🛡️ Remote Cheat Manager", style: TextStyle(color: Colors.amber)),
        content: Consumer<AppState>(
          builder: (context, state, child) {
            _urlCtrl.text = state.remoteCheatUrl;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("PENGATURAN MANUAL (Sekali Pakai)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                  TextField(
                    onChanged: (val) => state.setManualRiggedWinner(val),
                    decoration: InputDecoration(
                      hintText: state.riggedWinnerBib ?? "Kosong (Acak Murni)", 
                      helperText: "Ketik BIB pemenang di sini. Akan hilang setelah 1x undi."
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Divider(color: Colors.white24, thickness: 2),
                  const SizedBox(height: 10),
                  
                  const Text("LIVE GOOGLE SHEETS SYNC", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                  const SizedBox(height: 5),
                  const Text("1. Buat Spreadsheet, isi Cell A1 dengan BIB (Atau '-' untuk acak normal).\n2. Publish to web -> Format CSV.\n3. Paste link CSV di bawah ini.", style: TextStyle(fontSize: 12, color: Colors.white70)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(labelText: "Link CSV Google Sheets", border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            state.syncStatus, 
                            style: TextStyle(color: state.isRemoteCheatActive ? Colors.green : Colors.grey, fontWeight: FontWeight.bold, fontSize: 13)
                          ),
                        ),
                        Switch(
                          value: state.isRemoteCheatActive,
                          activeColor: Colors.amber,
                          onChanged: (val) => state.toggleRemoteCheat(_urlCtrl.text, val),
                        )
                      ],
                    ),
                  )
                ],
              ),
            );
          }
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("TUTUP", style: TextStyle(color: Colors.white)))
        ]
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final TextEditingController importController = TextEditingController();

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: () => _showCheatAuthentication(context),
          child: const Text('LAIRE BROADCAST KONTROL', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber))
        ), 
        backgroundColor: Colors.black
      ),
      body: Row(
        children: [
          // KOLOM 1: PENGATURAN
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
                    label: const Text('1-Klik Fullscreen (Layar 2)'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, padding: const EdgeInsets.all(12)),
                    onPressed: () => state.triggerRemoteFullscreen(),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    icon: Icon(state.showWinnerList ? Icons.visibility_off : Icons.visibility),
                    label: Text(state.showWinnerList ? 'SEMBUNYIKAN PEMENANG' : 'TAMPILKAN PEMENANG'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.showWinnerList ? Colors.grey : Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(12)
                    ),
                    onPressed: () => state.toggleWinnerList(),
                  ),
                  const SizedBox(height: 20),

                  const Text("KUSTOMISASI VISUAL", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  TextField(decoration: const InputDecoration(labelText: 'Judul Event', border: OutlineInputBorder()), onSubmitted: (val) => state.updateTitle(val)),
                  const SizedBox(height: 15),
                  
                  const Text("Pilih Font Angka & Pemenang", style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: state.selectedFont,
                        dropdownColor: Colors.grey[900],
                        items: state.availableFonts.map((String font) {
                          return DropdownMenuItem<String>(
                            value: font,
                            child: Text(font, style: GoogleFonts.getFont(font)),
                          );
                        }).toList(),
                        onChanged: (String? newFont) {
                          if (newFont != null) state.updateFont(newFont);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),

                  ElevatedButton.icon(icon: const Icon(Icons.image), label: const Text('1. Ganti GAMBAR Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(12)), onPressed: () => state.pickBackgroundImage()),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(icon: const Icon(Icons.format_color_fill), label: const Text('2. Ganti WARNA Latar'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(12)), onPressed: () => _showColorPicker(context, state, ColorTarget.background)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(icon: const Icon(Icons.branding_watermark), label: const Text('3. Ganti WARNA Box Angka'), style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white, padding: const EdgeInsets.all(12)), onPressed: () => _showColorPicker(context, state, ColorTarget.box)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(icon: const Icon(Icons.star), label: const Text('4. Ganti WARNA Popup Pemenang'), style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white, padding: const EdgeInsets.all(12)), onPressed: () => _showColorPicker(context, state, ColorTarget.popup)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(icon: const Icon(Icons.stadium), label: const Text('5. Ganti WARNA Background Logo'), style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white, padding: const EdgeInsets.all(12)), onPressed: () => _showColorPicker(context, state, ColorTarget.logoBg)),
                  const SizedBox(height: 25),

                  const Text("IMPORT DATA (Kolom 1: BIB, Kolom 2: Nama)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  const Divider(),
                  TextField(controller: importController, maxLines: 5, decoration: const InputDecoration(hintText: "Paste data Excel (Kolom Tab/Koma) di sini...", border: OutlineInputBorder(), filled: true, fillColor: Colors.black45)),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.all(15)),
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
                  const Text("LIVE PREVIEW (ABSOLUTE 16:9)", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, color: Colors.white54)),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Center(
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
                      itemBuilder: (context, i) => ListTile(dense: true, title: Text("${state.participants[i].bib} - ${state.participants[i].name}", style: const TextStyle(fontFamily: 'Courier', fontWeight: FontWeight.bold)), trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 16), onPressed: () => state.removeParticipant(i))),
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
                                Text("${w.participant.bib} - ${w.participant.name}", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, decoration: isHangus ? TextDecoration.lineThrough : null, color: isHangus ? Colors.redAccent : Colors.white)),
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

  void _showColorPicker(BuildContext context, AppState state, ColorTarget target) {
    Color tempColor; String title;
    if (target == ColorTarget.background) { tempColor = state.backgroundColor; title = 'Pilih Warna Latar'; }
    else if (target == ColorTarget.box) { tempColor = state.boxColor; title = 'Pilih Warna Box Angka'; }
    else if (target == ColorTarget.popup) { tempColor = state.popupColor; title = 'Pilih Warna Popup Pemenang'; }
    else { tempColor = state.logoBgColor; title = 'Pilih Warna Background Logo'; }
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(color: Colors.amber)),
        content: SingleChildScrollView(
          child: StatefulBuilder(builder: (context, setStateCb) {
            return ColorPicker(
              pickerColor: tempColor, onColorChanged: (color) {
                setStateCb(() => tempColor = color);
                if (target == ColorTarget.background) state.updateBackgroundColor(color);
                else if (target == ColorTarget.box) state.updateBoxColor(color);
                else if (target == ColorTarget.popup) state.updatePopupColor(color);
                else state.updateLogoBgColor(color);
              },
              enableAlpha: true, displayThumbColor: true, hexInputBar: true, portraitOnly: true,
            );
          })
        ),
        actions: [ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green), onPressed: () => Navigator.pop(context), child: const Text('SELESAI', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)))]
      ),
    );
  }
}

class RollingTextWidget extends StatefulWidget {
  final bool isSpinning;
  final Participant? finalWinner;
  final List<Participant> participants;
  final bool isPreview;
  final Color boxColor;
  final String selectedFont;

  const RollingTextWidget({ Key? key, required this.isSpinning, required this.finalWinner, required this.participants, required this.isPreview, required this.boxColor, required this.selectedFont }) : super(key: key);

  @override
  State<RollingTextWidget> createState() => _RollingTextWidgetState();
}

class _RollingTextWidgetState extends State<RollingTextWidget> with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  Participant _currentPart = Participant(bib: "READY", name: "DOORPRIZE");
  Duration _lastFrameTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (elapsed - _lastFrameTime > const Duration(milliseconds: 33)) {
        if (widget.isSpinning && widget.participants.isNotEmpty) {
          setState(() { _currentPart = widget.participants[Random().nextInt(widget.participants.length)]; });
        }
        _lastFrameTime = elapsed;
      }
    });
    if (widget.isSpinning) _ticker.start();
  }

  @override
  void didUpdateWidget(RollingTextWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSpinning && !oldWidget.isSpinning) _ticker.start();
    else if (!widget.isSpinning && oldWidget.isSpinning) _ticker.stop();
  }

  @override
  void dispose() { _ticker.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    Participant displayPart;
    if (widget.isSpinning) displayPart = _currentPart;
    else if (widget.finalWinner != null) displayPart = widget.finalWinner!;
    else displayPart = Participant(bib: "READY", name: "DOORPRIZE");

    return Container(
      width: widget.isPreview ? 200 : 1000, 
      height: widget.isPreview ? 85 : 350,
      decoration: BoxDecoration(color: widget.boxColor, borderRadius: BorderRadius.circular(widget.isPreview ? 15 : 30), border: Border.all(color: Colors.white24, width: widget.isPreview ? 2 : 4)),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(displayPart.bib.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.getFont(widget.selectedFont, fontSize: widget.isPreview ? 20 : 90, fontWeight: FontWeight.w900, color: Colors.amber, letterSpacing: widget.isPreview ? 2.0 : 6.0)),
            const SizedBox(height: 5),
            Text(displayPart.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.getFont(widget.selectedFont, fontSize: widget.isPreview ? 25 : 120, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: widget.isPreview ? 1.0 : 3.0)),
          ],
        ),
      ),
    );
  }
}

class RaffleDisplayView extends StatelessWidget {
  final bool isPreview;
  const RaffleDisplayView({Key? key, required this.isPreview}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    Widget canvas = Container(
      width: 1920, height: 1080,
      decoration: BoxDecoration(color: state.backgroundColor, image: state.backgroundBytes != null ? DecorationImage(image: MemoryImage(state.backgroundBytes!), fit: BoxFit.cover) : null),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(state.eventTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 90, fontWeight: FontWeight.w900, color: Colors.amber, letterSpacing: 8.0, shadows: [Shadow(color: Colors.black, blurRadius: 20, offset: Offset(0, 5))])),
                const SizedBox(height: 80),
                RollingTextWidget(isSpinning: state.isSpinning, finalWinner: state.finalWinner, participants: state.participants, isPreview: false, boxColor: state.boxColor, selectedFont: state.selectedFont),
              ],
            ),
          ),
          if (!isPreview && state.showWinnerList && state.winners.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 80),
                child: Container(
                  width: 550, padding: const EdgeInsets.all(30),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(25), border: Border.all(color: Colors.amber, width: 3)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("DAFTAR PEMENANG", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, fontSize: 30, letterSpacing: 3)),
                      const Divider(color: Colors.white24, thickness: 2, height: 30),
                      ...state.winners.take(5).map((w) {
                        bool isHangus = w.status == 'HANGUS';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(child: Text("${w.participant.bib} - ${w.participant.name}", overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: 'Courier', color: isHangus ? Colors.redAccent : Colors.white, fontWeight: FontWeight.bold, fontSize: 26, decoration: isHangus ? TextDecoration.lineThrough : null))),
                              if (isHangus) const Text("HANGUS", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 20))
                              else if (w.status == 'SAH') const Icon(Icons.check_circle, color: Colors.green, size: 30)
                            ],
                          ),
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 60),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 20),
                decoration: BoxDecoration(color: state.logoBgColor, borderRadius: BorderRadius.circular(100), border: Border.all(color: Colors.amber, width: 3), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 5)]),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/Preview-4.png', height: 50, errorBuilder: (_,__,___) => const Icon(Icons.star, color: Colors.amber, size: 50)),
                    const SizedBox(width: 25),
                    const Text("LAIRE CREATIVE STUDIO", style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w900, letterSpacing: 4.0, fontSize: 26)),
                  ],
                ),
              ),
            ),
          ),
          if (state.finalWinner != null)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.4), 
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.8, end: 1.0), duration: const Duration(milliseconds: 600), curve: Curves.elasticOut,
                    builder: (context, scale, child) {
                      return Transform.scale(
                        scale: scale,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 100, vertical: 80),
                          decoration: BoxDecoration(color: state.popupColor, borderRadius: BorderRadius.circular(50), border: Border.all(color: Colors.white, width: 10), boxShadow: [BoxShadow(color: state.popupColor.withOpacity(0.8), blurRadius: 100, spreadRadius: 20)]),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text("🎉 SELAMAT 🎉", style: TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 10, shadows: [Shadow(color: Colors.black87, blurRadius: 10)])),
                              const SizedBox(height: 30),
                              Text(state.finalWinner!.bib.toUpperCase(), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.getFont(state.selectedFont, fontSize: 100, fontWeight: FontWeight.w900, color: Colors.amberAccent, shadows: const [Shadow(color: Colors.black87, offset: Offset(4, 4), blurRadius: 10)])),
                              Text(state.finalWinner!.name.toUpperCase(), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.getFont(state.selectedFont, fontSize: 130, fontWeight: FontWeight.w900, color: Colors.white, shadows: const [Shadow(color: Colors.black87, offset: Offset(4, 4), blurRadius: 10)])),
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

    return Container(
      color: Colors.black, 
      child: Center(
        child: AspectRatio(aspectRatio: 16 / 9, child: FittedBox(fit: BoxFit.contain, child: canvas)),
      ),
    );
  }
}
