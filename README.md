# Tdarr Custom Script: Multi-Stream Smart TV Audio Optimizer

A robust, specialized Bash script designed to be executed within Tdarr Flows (e.g., via local CLI script execution plugins).

The core goal of this script is to solve a very specific problem: processing incoming video files containing multiple heavy, non-standard, or surround-sound audio tracks, and normalization-transcoding them into an optimized format designed for maximum compatibility with Smart TV capabilities (Stereo/Mono AAC/Copy) while cleanly stripping out unwanted commentary or single-voice/amateur translations.

## The Problem It Solves

When playing media files directly on certain Smart TVs via local networks, DLNA, or Plex/Jellyfin direct-play, files often fail to play sound, experience stuttering, or default to wrong tracks because:

- They contain heavy multi-channel audio codecs (DTS, TrueHD, 5.1/7.1 channel setups) that the TV hardware cannot natively decode.

- The tracks contain bloating audio channels like amateur voiceovers (Gobliln, Gavrilov, etc.) or director commentaries that disrupt automated playback selection.

- Tdarr variables passing paths with spaces or escaped slashes (&#x2F;) break standard script arguments, leading to parsing failures.

This script elegantly intercepts the files in the Tdarr cache pipeline, cleans the metadata, checks current configurations, and maps everything into a highly compliant structure.

## 🚀 Key Features
1. Smart TV Audio Normalization & Downmixing

- Mono/Stereo Preservation: If a track is already Mono (1.0) or Stereo (2.0), it is skipped for encoding and cloned using lightning-fast stream copying (-c:a copy) to preserve zero-overhead performance.

- Intelligent Surround Downmixing: Multi-channel streams (3 channels or higher like 5.1 and 7.1) are dynamically extracted, mixed down to AAC Stereo (2.0), and re-encoded at a clear 256k sound bitrate.

- Uniform Track Labeling: Rewrites stream titles inside the container into highly human-readable metadata labels (e.g., 2.0 (Russian - Studio) or 1.0 (English)) so they look beautiful and consistent on TV client menus.

- Fallback Protection: If every single audio track in a file happens to get filtered out by the exclusion rules, it safely falls back to preserving the very first track in standard AAC Stereo format to prevent silent outputs.

2. Audio Content Filtering (Amateur Translations & Commentaries)

The script uses aggressive regex pattern matching to drop heavy metadata bloat, automatically skipping audio tracks containing:

- Amateur / Single-Voice Voiceovers: Drops tracks explicitly containing names like Gavrilov, Volodar, Mikhalev, Serbin, Puchkov, Goblin, avo, одноголосый, авторский, etc.

- Director/Studio Commentaries: Automatically strips tracks designated as commentary or комментар.

3. Subtitle Engine Clean-up

- Text-Based Subtitles preserved: Standard text-based formats like SRT, ASS/SSA, WebVTT, or mov_text are securely copied over.

- Image-Based Subtitles stripped: Hardware-unfriendly bitmap image subtitle streams requiring optical character recognition—such as PGS (hdmv_pgs_subtitle), DVDSUB, and XSUB—are safely ignored since they frequently crash Smart TV media players or fail to load.

4. Bulletproof Pipeline Mechanics

- Dynamic Dependency Auto-Discovery: Automatically scans the Tdarr runtime mount space (/app) to find internal compiled binaries for ffmpeg and ffprobe. It appends them to $PATH dynamically, making the script fully autonomous regardless of host environmental changes.

- Advanced Space & Character Escape Fix: Features an argument parsing loop specifically designed to catch complex string splits. It repairs HTML forward-slashes (&#x2F;) and joins broken paths caused by multiple unescaped whitespaces following the -o parameter flag.

- Fast-Pass Optimizations: Inspects .mkv files natively. If a video is already an MKV file and its audio streams are already less than or equal to 2 channels, it executes an instantaneous filesystem copy and safe exits, saving massive processing cycles.

## 🛠️ Internal Processing Architecture

🛠️ Internal Processing Architecture

The script processes incoming files, maps audio/subtitle components, and handles execution errors through the following multi-stage pipeline:

    Initialization & Dependency Discovery

        Binary Auto-Detection: Dynamically scans the internal directory structure (/app) inside the Tdarr Node container to locate native ffmpeg and ffprobe binaries.

        Environment Setup: Prepends the discovered binary directories to the system $PATH to guarantee isolation and tool accessibility.

        Path Sanitization: Decodes HTML entities (e.g., converting &#x2F; back to /) and reassembles argument components that were fragmented by whitespaces during the Tdarr handover.

    Pre-Processing & Fast-Pass Assessment

        Sanity Checks: Validates that input paths are populated and files physically exist on disk, issuing a failure log and exit code 1 if missing.

        Format and Channel Verification: Probes the file structure using ffprobe. If the source file is an MKV container and its audio tracks are already within standard limits (≤ 2 channels), it triggers a fast-pass.

        Fast-Pass Execution: Automatically clones the source file to the output cache directory via an instantaneous file system copy and exits with status code 0, completely bypassing heavy processing streams.

    Stream Map Extraction & Component Filtering

        Video Tracks: Automatically locks onto the original video layers to keep them preserved with zero-copy stream cloning (-c:v copy).

        Subtitle Track Filtering: Evaluates codec metadata line-by-line:

            Retained: Clean, text-based subtitle arrays (SRT, ASS/SSA, WebVTT, mov_text).

            Discarded: Image-based bitmap tracks (PGS, DVDSUB, XSUB), avoiding player rendering issues on Smart TVs.

        Audio Track Filtering: Parses languages and descriptors against an exclusion regex index:

            Dropped Tracks: Audio streams flagged with single-voice/amateur translations (Goblin, Gavrilov, Serbin, etc.) or labeled as commentary.

            Retained Tracks: Valid audio components are passed down to the audio processing matrix.

    Audio Engineering Matrix

        Mono & Stereo Processing (≤ 2 Channels): Preserves native channel architecture, matches localization tags, and pipes the payload over using standard stream copy (copy).

        Surround Sound Processing (> 2 Channels): Intercepts multi-channel audio setups (such as 5.1 and 7.1 DTS/TrueHD configurations) and forces a high-fidelity downmix into standard AAC Stereo 2.0 at 256 kbps.

        Metadata Uniformity: Sanitizes and reformats stream names into clean navigation labels (e.g., 2.0 (Russian - Author)) and automatically targets the English track layout to assume the +default playback disposition.

        Fallback Logic: If strict criteria drop all available audio tracks, the script catches the exception and forces the first audio track to render as standard AAC Stereo 2.0 to avoid silent outputs.

    Multiplexing & Dynamic Execution

        Argument Compilation: Dynamically builds an optimized parameters index array grouping all newly mapped video, audio, and subtitle streams together.

        Live Stream Mapping Execution: Fires up an active ffmpeg sub-process configured to broadcast ongoing encoding statistics and frame-by-frame processing states directly through standard error descriptors.

        Real-Time Integration: Feeds progress outputs back into the Tdarr node console interface so users can watch live updates on their Tdarr dashboards.

    Post-Processing Validation

        Success Assertion (Exit 0): Validates the newly created cache file. If ffmpeg outputs a clean return status (0) and the file size is greater than zero, it updates /tmp/tdarr_script_processed.log and completes the job.

        Failure Isolation (Exit 1): If the execution fails or produces an empty file, it dumps error telemetry data directly into /tmp/tdarr_script_error.log to help with debugging and marks the node task as failed.

## Installation & Tdarr Workflow Configuration
1. Make the Script Executable

Ensure the file has executive permissions inside your Tdarr Node container or server host environment:
Bash

chmod +x video_converter.sh

2. Connect to Tdarr Flows

To link this into an automated pipeline workflow:

- Place video_converter.sh in a secure local directory accessible by your active Tdarr Node.

- In your Tdarr Flow workspace, add a plugin designed to call custom external local scripts (such as Tdarr_Plugin_vd01_Action_Run_Local_Script).

- Set your execution parameters exactly as shown below:
'''bash
-i "{{.inputFilePath}}" -o "{{.cacheFilePath}}"
'''

## 🔍 Diagnostics & Debug Logs

The script leaves clear logging tracks within volatile container space (/tmp) to help you debug file parsing issues:

/tmp/tdarr_args_debug.log: Detailed look at how parameters are being parsed. It logs the argument counts and how strings were reconstructed. Check this log if you experience pathing breaks.

/tmp/tdarr_script_processed.log: Simple timestamped history log recording files processed or fast-passed successfully.

/tmp/tdarr_script_error.log: Detailed capture containing exact error logs exported straight from ffmpeg standard error pipes if an execution step fails.