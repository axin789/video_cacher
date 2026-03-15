import 'package:flutter/material.dart';

class MiniActionButton extends StatelessWidget {
  const MiniActionButton({
    super.key,
    required this.label,
    this.onTap,
  });

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foregroundColor: Colors.white,
        side: BorderSide(
          color:
              onTap == null ? const Color(0xFF3A3A3A) : const Color(0xFF5B5B5B),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
