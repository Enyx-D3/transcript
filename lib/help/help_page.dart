import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/app_flushbar.dart';

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const String supportEmail = 'contact@enyx.app'; // ✅ change if needed
  static const String appName = 'Unlimited Meeting Transcription';

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0B0C10);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: const Text('Help'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            children: [
              _SendMessageCard(
                isDark: isDark,
                onTap: () => _contactSupport(context),
              ),
              const SizedBox(height: 12),

              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    const _SectionHeader(
                      title: 'Frequently asked questions',
                      subtitle: 'Tap a question to see the answer',
                    ),
                    const SizedBox(height: 8),

                    _FaqPanel(
                      isDark: isDark,
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

                    const SizedBox(height: 12),

                    _FooterNote(
                      isDark: isDark,
                      text:
                          'Tip: When contacting support, include your app version and a short description of the issue.',
                    ),
                  ],
                ),
              ),
            ],
          ),
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

// ---------------- UI ----------------

class _SendMessageCard extends StatelessWidget {
  const _SendMessageCard({required this.isDark, required this.onTap});

  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            color: Colors.black.withOpacity(0.25),
            offset: const Offset(0, 10),
          ),
        ],
      ),
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
                  color: Colors.white.withOpacity(0.06),
                  border: Border.all(color: Colors.white.withOpacity(0.10)),
                ),
                child: const Icon(Icons.mail_outline),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send us a message',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'We usually reply within 1–2 business days',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
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
  const _FaqPanel({required this.items, required this.isDark});

  final List<_FaqItem> items;
  final bool isDark;

  @override
  State<_FaqPanel> createState() => _FaqPanelState();
}

class _FaqPanelState extends State<_FaqPanel> {
  final Set<int> _open = {};

  @override
  Widget build(BuildContext context) {
    final border = (widget.isDark ? Colors.white : Colors.black).withOpacity(
      0.10,
    );

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: widget.items.length,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 0.6,
          color: Colors.white.withOpacity(0.08),
        ),
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
                          style: const TextStyle(fontWeight: FontWeight.w900),
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
                      style: const TextStyle(
                        color: Colors.white70,
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
  const _FooterNote({required this.isDark, required this.text});
  final bool isDark;
  final String text;

  @override
  Widget build(BuildContext context) {
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white70,
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
