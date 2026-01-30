import 'package:flutter/material.dart';

class HipaaFriendlyPage extends StatelessWidget {
  const HipaaFriendlyPage({super.key});

  static const _appName = 'Unlimited Meeting Transcription';

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0B0C10);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: const Text('HIPAA-friendly architecture'),
        leading: Padding(
          padding: const EdgeInsets.all(7.0),
          child: _IconPillButton(
            tooltip: 'Close',
            icon: Icons.arrow_back,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            children: [
              _InfoCard(isDark: isDark),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  children: const [
                    _Section(
                      title: 'Important note',
                      bullets: [
                        'We do not claim HIPAA certification.',
                        'HIPAA compliance depends on how you use the app, your policies, and your environment.',
                        'This page explains design choices that can help reduce privacy risk.',
                      ],
                    ),
                    SizedBox(height: 14),
                    _Section(
                      title: 'Privacy-first by default',
                      bullets: [
                        'Transcription is processed on-device (no transcript required to be sent to us).',
                        'Your transcripts are stored locally on your device unless you choose to export/share them.',
                        'You control what you share and where you share it.',
                      ],
                    ),
                    SizedBox(height: 14),
                    _Section(
                      title: 'Data minimization',
                      bullets: [
                        'We keep only store account realted data for verifying purchases.',
                        'You can delete transcripts (Trash keeps them temporarily for recovery).',
                        'Optional features (like auto-email) are user-controlled and can be turned off.',
                      ],
                    ),
                    SizedBox(height: 14),
                    _Section(
                      title: 'Security-minded workflow',
                      bullets: [
                        'If you export/share files, treat them as sensitive and store them in approved systems.',
                        'Use device lock + OS encryption and keep your phone updated.',
                        'Avoid sharing PHI in unsupported channels (public email inboxes, unsecured storage, etc.).',
                      ],
                    ),
                    SizedBox(height: 14),
                    _Section(
                      title: 'What we are NOT promising',
                      bullets: [
                        'No “HIPAA certified” claims.',
                        'No guarantee of compliance for your organization.',
                        'No replacement for legal/compliance review.',
                      ],
                    ),
                    SizedBox(height: 10),
                    // _Section(
                    //   title: 'Recommended best practices',
                    //   bullets: [
                    //     'Use a passcode/biometrics and enable device encryption.',
                    //     'Use approved storage for exports (enterprise Drive/SharePoint/etc.).',
                    //     'Limit who can access the device and exported files.',
                    //     'Consult your compliance team if you handle PHI.',
                    //   ],
                    // ),
                    // SizedBox(height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.isDark});
  final bool isDark;

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
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withOpacity(0.06),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
            ),
            child: const Icon(Icons.privacy_tip_outlined),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Designed to reduce risk',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 6),
                Text(
                  'We aim for a privacy-first architecture that can support HIPAA-conscious workflows when used appropriately.',
                  style: TextStyle(color: Colors.white70, height: 1.25),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.bullets});

  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
          ),
          const SizedBox(height: 10),
          ...bullets.map((t) => _Bullet(text: t)).toList(),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              Icons.circle,
              size: 7,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : Colors.black87,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
class _IconPillButton extends StatelessWidget {
  const _IconPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final border = (isDark ? Colors.white : Colors.black).withOpacity(0.10);
    final bg = (isDark ? Colors.white : Colors.black).withOpacity(0.06);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: bg,
          border: Border.all(color: border),
        ),
        child: Tooltip(
          message: tooltip,
          child: Icon(
            icon,
            color: onTap == null
                ? (isDark ? Colors.white38 : Colors.black38)
                : null,
          ),
        ),
      ),
    );
  }
}