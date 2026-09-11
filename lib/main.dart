import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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

class AppState extends ChangeNotifier {
  List<String> participants = ['Peserta 1', 'Peserta 2', 'Peserta 3'];
  String wheelTitle = "LAIRE CREATIVE UNDIAN";
  Color backgroundColor = const Color(0xFF121212);
  String? backgroundImagePath;
  
  final StreamController<int> spinController = StreamController<int>.broadcast();
  final AudioPlayer audioPlayer = AudioPlayer();

  void addParticipant(String name) {
    if (name.isNotEmpty) {
      participants.add(name);
      notifyListeners();
    }
  }

  void removeParticipant(int index) {
    if (participants.length > 2) {
      participants.removeAt(index);
      notifyListeners();
    }
  }

  void updateTitle(String newTitle) {
    wheelTitle = newTitle;
    notifyListeners();
  }

  void updateBackgroundColor(Color color) {
    backgroundColor = color;
    backgroundImagePath = null;
    notifyListeners();
  }

  Future<void> pickBackgroundImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      backgroundImagePath = result.files.single.path;
      notifyListeners();
    }
  }

  Future<void> spin() async {
    if (participants.isEmpty) return;
    
    await audioPlayer.play(AssetSource('spin_sound.mp3'));
    
    int winningIndex = Fortune.randomInt(0, participants.length);
    spinController.add(winningIndex);
  }
}

class LaireSpinwheelApp extends StatelessWidget {
  const LaireSpinwheelApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laire Spinwheel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.orange,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
      home: const OperatorScreen(),
    );
  }
}

class OperatorScreen extends StatelessWidget {
  const OperatorScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final TextEditingController nameController = TextEditingController();
    final TextEditingController titleController = TextEditingController(text: state.wheelTitle);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard Operator'),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DisplayScreen()));
              },
              icon: const Icon(Icons.cast),
              label: const Text("Buka Layar Display"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(24.0),
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: Colors.white12)),
              ),
              child: ListView(
                children: [
                  Center(
                    child: Image.asset('assets/Preview-4.png', height: 100, errorBuilder: (context, error, stackTrace) => const Icon(Icons.image, size: 100, color: Colors.orange)),
                  ),
                  const SizedBox(height: 30),
                  const Text("Kustomisasi Visual", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange)),
                  const Divider(color: Colors.white24),
                  const SizedBox(height: 10),
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(
                      labelText: 'Judul Undian',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (val) => state.updateTitle(val),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.color_lens),
                    label: const Text('Ubah Warna Solid'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                    onPressed: () => _showColorPicker(context, state),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.image),
                    label: const Text('Ganti Gambar Background'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
                    onPressed: () => state.pickBackgroundImage(),
                  ),
                  const SizedBox(height: 50),
                  SizedBox(
                    width: double.infinity,
                    height: 60,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => state.spin(),
                      child: const Text('PUTAR RODA', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Daftar Peserta", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange)),
                      Text("Total: ${state.participants.length}", style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nameController,
                          decoration: const InputDecoration(
                            hintText: 'Ketik nama peserta dan tekan Enter...',
                            border: OutlineInputBorder(),
                            filled: true,
                            fillColor: Colors.black26,
                          ),
                          onSubmitted: (val) {
                            state.addParticipant(val);
                            nameController.clear();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 55,
                        child: ElevatedButton(
                          onPressed: () {
                            state.addParticipant(nameController.text);
                            nameController.clear();
                          },
                          child: const Text('Tambah'),
                        ),
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
                            leading: CircleAvatar(
                              backgroundColor: Colors.orange,
                              child: Text('${index + 1}', style: const TextStyle(color: Colors.white)),
                            ),
                            title: Text(state.participants[index], style: const TextStyle(fontSize: 16)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
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
        title: const Text('Pilih Warna Background Display'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: state.backgroundColor,
            onColorChanged: (color) => state.updateBackgroundColor(color),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Selesai'),
          ),
        ],
      ),
    );
  }
}

class DisplayScreen extends StatelessWidget {
  const DisplayScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          color: state.backgroundColor,
          image: state.backgroundImagePath != null
              ? DecorationImage(
                  image: FileImage(File(state.backgroundImagePath!)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: Stack(
          children: [
            Positioned(
              top: 40,
              left: 40,
              child: Image.asset('assets/Preview-4.png', height: 120, errorBuilder: (context, error, stackTrace) => const SizedBox()),
            ),
            Positioned(
              top: 40,
              right: 40,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white24, size: 40),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(
                      state.wheelTitle,
                      style: const TextStyle(
                        fontSize: 52,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                  const SizedBox(height: 60),
                  SizedBox(
                    height: 600,
                    width: 600,
                    child: FortuneWheel(
                      selected: state.spinController.stream,
                      animateFirst: false,
                      physics: CircularPanPhysics(
                        duration: const Duration(seconds: 4),
                        curve: Curves.decelerate,
                      ),
                      items: [
                        for (var it in state.participants)
                          FortuneItem(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text(it, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                            ),
                            style: const FortuneItemStyle(
                              color: Colors.orange,
                              borderColor: Colors.black87,
                              borderWidth: 4,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
