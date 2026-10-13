import 'package:flutter/material.dart';

/// The exhibition's square-edged frame, without its wall or spotlights.
class BloomArtworkFrame extends StatelessWidget {
  const BloomArtworkFrame({super.key, required this.child});

  static const imageInset = 8.5;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff545049), Color(0xff282824), Color(0xff48453e)],
      ),
      border: Border.all(color: const Color(0xff262622), width: 1),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .23),
          blurRadius: 16,
          spreadRadius: 1,
          offset: const Offset(5, 10),
        ),
      ],
    ),
    child: Container(
      padding: const EdgeInsets.all(1.5),
      color: const Color(0xffbbb6a9),
      child: ClipRect(child: child),
    ),
  );
}
