import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const RipploApp());
}

class RipploApp extends StatelessWidget {
  const RipploApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Ripplo',
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Color(0xFF0B0B0C)),
    );
  }
}
