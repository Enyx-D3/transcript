// lib/help/help_page.dart
import 'package:flutter/material.dart';
import 'package:transcript/widgets/icon_pill_button.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/app_flushbar.dart';

// ✅ Glass primitives

import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const String supportEmail = 'contact@enyx.app';
  static const String appName = 'Unlimited Meeting Transcription';

  @override
  Widget build(BuildContext context) {
    final fg = GlassTokens.fg(context, alpha: 0.92);

    return Scaffold(
      backgroundColor: GlassTokens.backgroundColor(context),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ✅ page-wide glass background
          // Positioned.fill(
          //   child: IgnorePointer(
          //     child: LiquidGlass(
          //       borderRadius: BorderRadius.zero,
          //       padding: EdgeInsets.zero,
          //       shadow: false,
          //       blurX: isDark ? 26 : 20,
          //       blurY: isDark ? 26 : 20,
          //       tintOpacityDark: 0.020,
          //       tintOpacityLight: 0.018,
          //       borderOpacityDark: 0.00,
          //       borderOpacityLight: 0.00,
          //       child: const SizedBox.expand(),
          //     ),
          //   ),
          // ),
          SafeArea(
            child: Column(
              children: [
                // ✅ Header row (no AppBar)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      IconPillButton(
                        tooltip: 'back',
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),

                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Help',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                            color: fg,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: GlassDivider(),
                ),
                const SizedBox(height: 10),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: Column(
                      children: [
                        _SendMessageCard(onTap: () => _contactSupport(context)),
                        const SizedBox(height: 12),

                        Expanded(
                          child: ListView(
                            physics: const BouncingScrollPhysics(),
                            children: const [
                              _SectionHeader(
                                title: 'Frequently asked questions',
                                subtitle: 'Tap a question to see the answer',
                              ),
                              SizedBox(height: 8),
                              _FaqPanel(
                                items: [
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
                              SizedBox(height: 12),
                              _FooterNote(
                                text:
                                    'Tip: When contacting support, include your app version and a short description of the issue.',
                              ),
                              SizedBox(height: 72),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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

// ---------------- UI ----------------

class _SendMessageCard extends StatelessWidget {
  const _SendMessageCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: 0.92);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: Icon(Icons.mail_outline, color: fg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send us a message',
                      style: TextStyle(fontWeight: FontWeight.w900, color: fg),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'We usually reply within 1–2 business days',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.70),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: fg.withValues(alpha: 0.85)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final isDark = GlassTokens.isDark(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.92)
                  : Colors.black87,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

class _FaqItem {
  final String q;
  final String a;
  const _FaqItem({required this.q, required this.a});
}

class _FaqPanel extends StatefulWidget {
  const _FaqPanel({required this.items});
  final List<_FaqItem> items;

  @override
  State<_FaqPanel> createState() => _FaqPanelState();
}

class _FaqPanelState extends State<_FaqPanel> {
  final Set<int> _open = {};

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: 0.92);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: EdgeInsets.zero,
      child: ListView.separated(
        itemCount: widget.items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, _) => const GlassDivider(),
        itemBuilder: (ctx, i) {
          final item = widget.items[i];
          final isOpen = _open.contains(i);

          return InkWell(
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
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.q,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: fg,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        isOpen
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                  if (isOpen) ...[
                    const SizedBox(height: 8),
                    Text(
                      item.a,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.70),
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final fg = Colors.white.withValues(alpha: 0.92);

    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: fg.withValues(alpha: 0.85)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                height: 1.25,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
