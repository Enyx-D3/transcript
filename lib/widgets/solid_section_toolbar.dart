import 'package:flutter/material.dart';

class SolidSelectionToolbar extends StatelessWidget {
  const SolidSelectionToolbar({
    super.key,
    required this.editableTextState,
    this.backgroundColor = const Color(0xFF101018),
  });

  final EditableTextState editableTextState;
  final Color backgroundColor;

  String _resolveLabel(ContextMenuButtonItem item) {
    if (item.label != null && item.label!.trim().isNotEmpty) {
      return item.label!;
    }

    switch (item.type) {
      case ContextMenuButtonType.cut:
        return 'Cut';
      case ContextMenuButtonType.copy:
        return 'Copy';
      case ContextMenuButtonType.paste:
        return 'Paste';
      case ContextMenuButtonType.selectAll:
        return 'Select all';
      case ContextMenuButtonType.share:
        return 'Share';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = editableTextState.contextMenuButtonItems;
    final anchors = editableTextState.contextMenuAnchors;

    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      children: [
        Center(
          // ✅ ensures proper centering
          child: IntrinsicWidth(
            // ✅ prevents full width expansion
            child: Material(
              color: backgroundColor,
              elevation: 10,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Wrap(
                  alignment: WrapAlignment.center, // ✅ center buttons
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final item in items)
                      TextButton(
                        onPressed: item.onPressed,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          _resolveLabel(item),
                          textAlign: TextAlign.center, // ✅ center text
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
