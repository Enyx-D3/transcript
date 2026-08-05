// lib/onboarding/enroll_prompts.dart
import 'package:flutter/foundation.dart';

@immutable
class EnrollmentPrompt {
  final String id; // stable key, e.g. "neutral", "loud"
  final String title; // UI header
  final String subtitle; // short instruction
  final String script; // what to say (displayed)
  final double minSec; // require at least this much audio
  final String? audioAsset; // can be an asset path OR a full URL
  const EnrollmentPrompt({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.script,
    this.minSec = 2.0,
    this.audioAsset,
  });
}

/// Longer (≈6–8s) prompts + public guide audio (OSR 8k WAV).
const List<EnrollmentPrompt> kDefaultEnrollmentPrompts = [
  EnrollmentPrompt(
    id: 'neutral',
    title: 'Neutral voice',
    subtitle: 'Speak naturally at a normal distance.',
    script:
        'Hi, this is my normal speaking voice for enrollment. I’m talking at a comfortable, natural pace in a quiet room so you can capture a clear sample. I’ll keep speaking for a few more seconds to give you enough audio to analyze my voice consistently.',
    minSec: 7,
    audioAsset: 'instruction/neutral.wav',
  ),
  EnrollmentPrompt(
    id: 'soft',
    title: 'Soft / quiet',
    subtitle: 'Lower volume, same distance.',
    script:
        'Now I’m speaking more softly and gently, without whispering. I’m keeping the microphone at the same distance while reducing my volume so it remains understandable.',
    minSec: 7,
    audioAsset: 'instruction/soft.wav',
  ),
  EnrollmentPrompt(
    id: 'loud',
    title: 'Loud / energetic',
    subtitle: 'Project clearly—do not shout.',
    script:
        'This sample is a bit louder and more energetic than usual. I’m projecting my voice clearly without shouting, keeping the phone at the same distance as before.',
    minSec: 7,
    audioAsset: 'instruction/loud.wav',
  ),
  EnrollmentPrompt(
    id: 'fast',
    title: 'Faster pace',
    subtitle: 'A little faster but still clear.',
    script:
        'Here is a faster sample with a quicker pace. Even though I’m speaking more rapidly, I’ll keep every word distinct and easy to understand. I’m maintaining clear pronunciation and steady volume so you can test how well the system handles faster speech.',
    minSec: 7,
    audioAsset: 'instruction/fast.wav',
  ),
  EnrollmentPrompt(
    id: 'far',
    title: 'Farther distance',
    subtitle: 'Hold the phone 30–50 cm away.',
    script:
        'For this sample I’m moving the phone a little farther away, around thirty to fifty centimeters, to simulate distance while still speaking naturally and clearly.',
    minSec: 7,
    audioAsset: 'instruction/far.wav',
  ),
];

/// If you want to switch sets dynamically later (e.g. remote config),
/// wrap access through a function:
List<EnrollmentPrompt> enrollmentPrompts() => kDefaultEnrollmentPrompts;
