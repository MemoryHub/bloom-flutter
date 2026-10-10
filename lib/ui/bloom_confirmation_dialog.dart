import 'package:flutter/material.dart';
import 'bloom_glass_home.dart';

Future<bool> confirmBloomAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder:
          (context) => Dialog(
            backgroundColor: Colors.transparent,
            child: BloomPanel(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: BloomType.sectionTitle),
                  const SizedBox(height: 14),
                  Text(message, style: BloomType.body),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消', style: BloomType.button),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: BloomPrimaryButton(
                          label: confirmLabel,
                          onPressed: () => Navigator.pop(context, true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    ) ??
    false;
