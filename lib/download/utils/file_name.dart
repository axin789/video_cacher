String sanitizeFileName(String input, {String fallback = 'video'}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return fallback;
  final replaced = trimmed
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (replaced.isEmpty) return fallback;
  return replaced.length > 120 ? replaced.substring(0, 120) : replaced;
}
