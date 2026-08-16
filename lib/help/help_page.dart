import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/app_flushbar.dart';
import '../ui/glass/glass_tokens.dart';

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const String supportEmail = 'contact@enyx.app';
  static const String appName = 'Meeting Transcript Unlimited';

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final primaryColor = GlassTokens.primary(context);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  IconPillButton(
                    tooltip: 'Back',
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Help & Support',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Divider(
              height: 1,
              thickness: 1,
              color: GlassTokens.borderColor(context),
            ),

            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  // Send message / contact card
                  _SendMessageCard(
                    primaryColor: primaryColor,
                    onTap: () => _contactSupport(context),
                  ),

                  const SizedBox(height: 24),

                  _SectionHeader(
                    title: 'Frequently asked questions',
                    subtitle: 'Tap a question to see the detailed answer',
                    primaryColor: primaryColor,
                  ),

                  const SizedBox(height: 12),

                  _FaqPanel(
                    primaryColor: primaryColor,
                    items: const [
                      _FaqItem(
                        q: 'Do I need internet for audio recording and transcription?',
                        a: 'No. Audio recording and transcription work fully offline on your device. An internet connection is only required for account verification, purchases, or restoring subscriptions.',
                      ),
                      _FaqItem(
                        q: 'Where are my transcripts stored?',
                        a: 'Your transcripts are stored locally on your device. If you export or share them, they will also exist wherever you send them.',
                      ),
                      _FaqItem(
                        q: 'How do I restore a deleted transcript?',
                        a: 'Deleted transcripts go to Trash first. Open Settings → Support → Trash and restore it within 3 days.',
                      ),
                      _FaqItem(
                        q: 'Why does transcription take time?',
                        a: 'Transcription speed depends on audio length, your device performance, and whether diarization/translation are enabled.',
                      ),
                      _FaqItem(
                        q: 'Can the app identify different speakers in a recording?',
                        a: 'Yes. The app can identify different speakers using on-device processing. Because all analysis happens locally, speaker detection may not always be perfectly accurate.',
                      ),
                      _FaqItem(
                        q: 'How accurate is the AI transcription?',
                        a: 'Transcription accuracy typically ranges from around 80% up to near 100%. Accuracy depends on language, audio quality, background noise, accents, and speaking clarity.',
                      ),
                      _FaqItem(
                        q: 'Does the AI add words that were not spoken?',
                        a: 'No. The AI does not intentionally add words that were not spoken. Any errors usually result from unclear or overlapping audio.',
                      ),
                      _FaqItem(
                        q: 'My Pro purchase didn’t unlock. What should I do?',
                        a: 'Go to Account and click Get Pro and use Restore Purchases. If it still doesn’t unlock, contact support and include your account email.',
                      ),
                      _FaqItem(
                        q: 'Is this recorder suitable for legal or forensic use?',
                        a: 'This app is designed for meetings, lectures, interviews, and personal use. It is not intended to replace certified legal or forensic transcription services where absolute precision or official certification is required.',
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  _FooterNote(
                    text:
                        'Tip: When contacting support, include your app version and a short description of the issue.',
                    primaryColor: primaryColor,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _contactSupport(BuildContext context) async {
    await AppFlushbar.info(context, message: 'Email: $supportEmail');

    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      queryParameters: {'subject': '$appName — Support'},
    );

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // ignore
    }
  }
}

// ---------------- UI Widgets ----------------

class _SendMessageCard extends StatelessWidget {
  const _SendMessageCard({
    required this.primaryColor,
    required this.onTap,
  });

  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Container(
      decoration: BoxDecoration(
        color: GlassTokens.cardColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTokens.borderColor(context), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.10),
                  ),
                  child: Icon(Icons.mail_outline_rounded, color: primaryColor, size: 23),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Send us a message',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'We usually reply within 1–2 business days',
                        style: TextStyle(
                          color: muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: muted, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.primaryColor,
  });

  final String title;
  final String subtitle;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 14,
              decoration: BoxDecoration(
                color: primaryColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.1,
                color: fg,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: muted,
            ),
          ),
        ),
      ],
    );
  }
}

class _FaqItem {
  final String q;
  final String a;
  const _FaqItem({required this.q, required this.a});
}

class _FaqPanel extends StatefulWidget {
  const _FaqPanel({
    required this.items,
    required this.primaryColor,
  });

  final List<_FaqItem> items;
  final Color primaryColor;

  @override
  State<_FaqPanel> createState() => _FaqPanelState();
}

class _FaqPanelState extends State<_FaqPanel> {
  final Set<int> _open = {};

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    final fg = GlassTokens.fg(context);
    final muted = GlassTokens.muted(context);

    return Container(
      decoration: BoxDecoration(
        color: GlassTokens.cardColor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTokens.borderColor(context), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: List.generate(widget.items.length, (i) {
            final item = widget.items[i];
            final isOpen = _open.contains(i);
            final isLast = i == widget.items.length - 1;

            return Column(
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        if (isOpen) {
                          _open.remove(i);
                        } else {
                          _open.add(i);
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.q,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    color: isOpen ? widget.primaryColor : fg,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              AnimatedRotation(
                                turns: isOpen ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: isOpen ? widget.primaryColor : muted,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                          if (isOpen) ...[
                            const SizedBox(height: 10),
                            Text(
                              item.a,
                              style: TextStyle(
                                color: muted,
                                height: 1.45,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (!isLast)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: GlassTokens.borderColor(context),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote({
    required this.text,
    required this.primaryColor,
  });

  final String text;
  final Color primaryColor;

  @override
  Widget build(BuildContext context) {
    final muted = GlassTokens.muted(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: GlassTokens.cardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GlassTokens.borderColor(context), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: primaryColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: muted,
                height: 1.35,
                fontWeight: FontWeight.w500,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
