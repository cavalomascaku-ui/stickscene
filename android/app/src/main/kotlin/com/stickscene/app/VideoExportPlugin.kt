package com.stickscene.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

/**
 * Exports a sequence to MP4, with sound.
 *
 * Video: MediaCodec H.264, fed by drawing each frame into the codec's input
 * Surface. That avoids hand-writing a colour-space conversion and is the
 * approach Android's own screen recorders use.
 *
 * Audio: every imported sound is decoded to PCM, mixed at its timeline offset,
 * encoded to AAC in a temp file, and its track format is registered with the
 * muxer *before* muxing starts.
 *
 * MediaMuxer refuses to add a track once start() has been called, so the mux is
 * only started once BOTH tracks are known. That ordering is the whole reason
 * the audio is prepared up front instead of after the video pass.
 *
 * Driven from Dart:
 *   startExport(path, width, height, fps, bitrate, durationMs, audioTracks)
 *   addFrame(pngBytes, index)     // one per animation frame, in order
 *   finishExport()                -> { path, frames, durationMs, hasAudio }
 *   cancelExport()
 */
class VideoExportPlugin : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "stickscene/video"
        private const val MIME_VIDEO = "video/avc"
        private const val MIME_AUDIO = "audio/mp4a-latm"
        private const val COLOR_FORMAT_SURFACE = 0x7F000789
        private const val SAMPLE_RATE = 44100
        private const val STEREO_CHANNELS = 2
        private const val TIMEOUT_US = 10_000L
    }

    private var session: Session? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startExport" -> { startExport(call, result) }
                "addFrame" -> {
                    val bytes = call.argument<ByteArray>("png")
                        ?: throw IllegalArgumentException("png payload is required")
                    val index = call.argument<Int>("index") ?: 0
                    session?.addFrame(bytes, index)
                    result.success(null)
                }
                "finishExport" -> {
                    val s = session ?: throw IllegalStateException("no export in progress")
                    val summary = s.finish()
                    session = null
                    result.success(summary)
                }
                "cancelExport" -> {
                    session?.release()
                    session = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            session?.release()
            session = null
            result.error("VIDEO_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun startExport(call: MethodCall, result: MethodChannel.Result) {
        session?.release()

        val path = call.argument<String>("path")
            ?: throw IllegalArgumentException("path is required")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val fps = call.argument<Int>("fps") ?: 12
        val durationMs = call.argument<Long>("durationMs") ?: 0L
        val bitrate = call.argument<Int>("bitrate")
            ?: (width * height * 4 * fps).coerceIn(1_000_000, 20_000_000)
        if (width <= 0 || height <= 0) {
            throw IllegalArgumentException("invalid video size ${width}x$height")
        }

        val audioArgs =
            call.argument<List<Map<String, Any?>>>("audioTracks") ?: emptyList()
        val tracks = audioArgs.mapNotNull { m ->
            val p = m["path"] as? String ?: return@mapNotNull null
            AudioTrackSpec(
                path = p,
                startMs = (m["startMs"] as? Number)?.toLong() ?: 0L,
                volume = (m["volume"] as? Number)?.toFloat() ?: 1f,
                durationMs = (m["durationMs"] as? Number)?.toLong() ?: 0L
            )
        }

        val created = Session(
            outputPath = path,
            width = width,
            height = height,
            fps = fps,
            bitrate = bitrate,
            durationMs = durationMs,
            audioTracks = tracks
        )
        created.start()
        session = created
        result.success(mapOf("ok" to true, "hasAudio" to tracks.isNotEmpty()))
    }

    private data class AudioTrackSpec(
        val path: String,
        val startMs: Long,
        val volume: Float,
        val durationMs: Long
    )

    private class Session(
        private val outputPath: String,
        private val width: Int,
        private val height: Int,
        private val fps: Int,
        private val bitrate: Int,
        private val durationMs: Long,
        private val audioTracks: List<AudioTrackSpec>
    ) {
        private var encoder: MediaCodec? = null
        private var surface: Surface? = null
        private var muxer: MediaMuxer? = null

        private var videoTrackIndex = -1
        private var audioTrackIndex = -1
        private var muxerStarted = false

        private val info = MediaCodec.BufferInfo()
        private val frameRect = Rect(0, 0, width, height)
        private var frameCount = 0
        private var scratch: Bitmap? = null

        /** Temporary AAC produced up front so its format can join the mux. */
        private var audioFile: File? = null

        fun start() {
            File(outputPath).parentFile?.mkdirs()

            // Audio first: its track format has to be registered before the
            // muxer can start, and the video format only becomes known after
            // the encoder warms up.
            prepareAudio()

            val format = MediaFormat.createVideoFormat(MIME_VIDEO, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, COLOR_FORMAT_SURFACE)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                // One keyframe per second keeps seeking usable without making
                // the file much bigger.
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }

            val codec = MediaCodec.createEncoderByType(MIME_VIDEO)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val inputSurface = codec.createInputSurface()
            codec.start()

            encoder = codec
            surface = inputSurface
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            audioFile?.let { file ->
                readAudioFormat(file)?.let { fmt ->
                    audioTrackIndex = muxer?.addTrack(fmt) ?: -1
                }
            }
        }

        fun addFrame(pngBytes: ByteArray, index: Int) {
            val codec = encoder ?: return
            val inputSurface = surface ?: return
            val bitmap = decodePng(pngBytes)

            var canvas = try {
                inputSurface.lockCanvas(null)
            } catch (first: Throwable) {
                // A surface can need a moment after start(); one retry is
                // enough in practice and beats losing the whole export.
                Thread.sleep(30)
                inputSurface.lockCanvas(null)
            }

            try {
                canvas.drawBitmap(bitmap, null, frameRect, null)
            } finally {
                try {
                    inputSurface.unlockCanvasAndPost(canvas)
                } finally {
                    bitmap.recycle()
                    scratch = null
                }
            }

            drain(codec, endOfStream = false)
            frameCount = max(frameCount, index + 1)
        }

        fun finish(): Map<String, Any?> {
            val codec = encoder
            if (codec != null) {
                try {
                    signalEndOfInputStream(codec)
                    drain(codec, endOfStream = true)
                } finally {
                    releaseEncoder()
                }
            }
            stopMuxer()

            val duration = if (fps > 0 && frameCount > 0) {
                frameCount * 1000L / fps
            } else {
                durationMs
            }

            audioFile?.delete()

            return mapOf(
                "path" to outputPath,
                "frames" to frameCount,
                "durationMs" to duration,
                "hasAudio" to (audioTrackIndex >= 0)
            )
        }

        private fun signalEndOfInputStream(codec: MediaCodec) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                codec.signalEndOfInputStream()
            } else {
                // Pre-Q has no signalEndOfInputStream; a zero-length buffer is
                // the documented workaround.
                val bufferId = codec.dequeueInputBuffer(TIMEOUT_US)
                if (bufferId >= 0) {
                    codec.queueInputBuffer(
                        bufferId, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                    )
                }
            }
        }

        private fun drain(codec: MediaCodec, endOfStream: Boolean) {
            var idleSpins = 0
            while (true) {
                val index = codec.dequeueOutputBuffer(info, if (endOfStream) TIMEOUT_US else 0L)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!endOfStream) return
                        // Keep spinning at end of stream, but bail out rather
                        // than hang forever if the codec never signals EOS.
                        idleSpins++
                        if (idleSpins > 500) return
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (videoTrackIndex < 0) {
                            videoTrackIndex = muxer?.addTrack(codec.outputFormat) ?: -1
                        }
                        maybeStartMuxer()
                    }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)
                        val isConfig =
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        if (buffer != null && info.size > 0 && !isConfig && muxerStarted) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer?.writeSampleData(videoTrackIndex, buffer, info)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                    }
                }
            }
        }

        private fun maybeStartMuxer() {
            if (muxerStarted) return
            if (videoTrackIndex < 0) return
            val m = muxer ?: return
            // Audio is optional; video alone is a valid MP4.
            if (audioTrackIndex < 0 && audioFile != null) return
            m.start()
            muxerStarted = true
        }

        // -------------------------------------------------------------------
        // Audio
        // -------------------------------------------------------------------

        private fun prepareAudio() {
            if (audioTracks.isEmpty()) return

            val span = audioTracks.maxOfOrNull { it.startMs + it.durationMs } ?: return
            if (span <= 0) return
            val totalSamples = ((span + 10) * SAMPLE_RATE / 1000).toInt()
            if (totalSamples <= 0) return

            val mix = ShortArray(totalSamples * STEREO_CHANNELS)
            var mixedAnything = false

            for (track in audioTracks) {
                val pcm = decodeToPcm(track.path) ?: continue
                val offsetSamples = (track.startMs * SAMPLE_RATE / 1000).toInt().coerceAtLeast(0)
                val gain = track.volume.coerceIn(0f, 4f)

                var i = 0
                while (i < pcm.size) {
                    val outIndex = offsetSamples * STEREO_CHANNELS + i
                    if (outIndex < 0) {
                        i += STEREO_CHANNELS
                        continue
                    }
                    if (outIndex >= mix.size) break
                    mix[outIndex] = clampSample(mix[outIndex] + (pcm[i] * gain).toInt())
                    if (i + 1 < pcm.size && outIndex + 1 < mix.size) {
                        mix[outIndex + 1] =
                            clampSample(mix[outIndex + 1] + (pcm[i + 1] * gain).toInt())
                    }
                    i += STEREO_CHANNELS
                }
                mixedAnything = true
            }

            if (!mixedAnything) return

            val tmp = File(outputPath + ".audio.aac")
            tmp.delete()
            if (encodeAac(mix, tmp)) {
                audioFile = tmp
            } else {
                tmp.delete()
            }
        }

        private fun readAudioFormat(file: File): MediaFormat? {
            val extractor = MediaExtractor()
            return try {
                extractor.setDataSource(file.absolutePath)
                var found: MediaFormat? = null
                for (i in 0 until extractor.trackCount) {
                    val f = extractor.getTrackFormat(i)
                    val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("audio/")) {
                        found = f
                        break
                    }
                }
                found
            } catch (_: Throwable) {
                null
            } finally {
                try {
                    extractor.release()
                } catch (_: Throwable) {
                }
            }
        }

        /** Decodes any supported audio file into 44.1 kHz interleaved stereo PCM. */
        private fun decodeToPcm(path: String): ShortArray? {
            val file = File(path)
            if (!file.exists() || file.length() == 0L) return null

            val extractor = MediaExtractor()
            var codec: MediaCodec? = null
            try {
                extractor.setDataSource(path)

                var trackIndex = -1
                var inputFormat: MediaFormat? = null
                for (i in 0 until extractor.trackCount) {
                    val f = extractor.getTrackFormat(i)
                    val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("audio/")) {
                        trackIndex = i
                        inputFormat = f
                        break
                    }
                }
                if (trackIndex < 0 || inputFormat == null) return null

                val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
                codec = MediaCodec.createDecoderByType(mime)
                codec.configure(inputFormat, null, null, 0)
                codec.start()
                extractor.selectTrack(trackIndex)

                val collected = ArrayList<Short>(1 shl 16)
                val bufferInfo = MediaCodec.BufferInfo()

                var inputChannels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var inputRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var outputFormatSeen = false
                var inputFinished = false

                while (true) {
                    if (!inputFinished) {
                        val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (inputIndex >= 0) {
                            val buffer = codec.getInputBuffer(inputIndex)
                            val size =
                                if (buffer == null) -1
                                else extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(
                                    inputIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputFinished = true
                            } else {
                                codec.queueInputBuffer(
                                    inputIndex, 0, size, extractor.sampleTime, 0
                                )
                                extractor.advance()
                            }
                        }
                    }

                    val outputIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                    when {
                        outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (inputFinished) break
                        }
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = codec.outputFormat
                            if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                inputChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            }
                            if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                                inputRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            }
                            outputFormatSeen = true
                        }
                        outputIndex >= 0 -> {
                            val buffer = codec.getOutputBuffer(outputIndex)
                            if (buffer != null && bufferInfo.size > 0) {
                                buffer.position(bufferInfo.offset)
                                buffer.limit(bufferInfo.offset + bufferInfo.size)
                                val shorts = ShortArray(bufferInfo.size / 2)
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                    .asShortBuffer().get(shorts)
                                for (v in shorts) collected.add(v)
                            }
                            codec.releaseOutputBuffer(outputIndex, false)
                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                        }
                    }
                }

                if (collected.isEmpty()) return null
                return toStereo44100(collected.toShortArray(), inputChannels, inputRate)
            } catch (_: Throwable) {
                return null
            } finally {
                try {
                    codec?.stop()
                } catch (_: Throwable) {
                }
                try {
                    codec?.release()
                } catch (_: Throwable) {
                }
                try {
                    extractor.release()
                } catch (_: Throwable) {
                }
            }
        }

        /**
         * Converts decoded PCM to interleaved 44.1 kHz stereo.
         *
         * Mono is duplicated to both channels. Sample-rate conversion uses
         * linear interpolation, which is inaudible for short sound effects and
         * avoids pulling in a resampling library.
         */
        private fun toStereo44100(input: ShortArray, channels: Int, rate: Int): ShortArray {
            val ch = if (channels <= 0) 1 else channels
            if (rate == SAMPLE_RATE && ch == STEREO_CHANNELS) return input

            val inputFrames = input.size / ch
            if (inputFrames <= 0) return input

            val outFrames = if (rate == SAMPLE_RATE) {
                inputFrames
            } else {
                ((inputFrames.toLong() * SAMPLE_RATE) / rate).toInt().coerceAtLeast(1)
            }
            val out = ShortArray(outFrames * STEREO_CHANNELS)

            fun sampleAt(frame: Int, channel: Int): Float {
                val idx = frame * ch + channel.coerceAtMost(ch - 1)
                return if (idx < input.size) input[idx].toFloat() else 0f
            }

            for (i in 0 until outFrames) {
                val exact = if (rate == SAMPLE_RATE) {
                    i.toDouble()
                } else {
                    i.toDouble() * rate / SAMPLE_RATE
                }
                val i0 = exact.toInt().coerceIn(0, inputFrames - 1)
                val i1 = (i0 + 1).coerceIn(0, inputFrames - 1)
                val t = (exact - i0).toFloat()

                val l = sampleAt(i0, 0) * (1 - t) + sampleAt(i1, 0) * t
                val r = if (ch >= 2) {
                    sampleAt(i0, 1) * (1 - t) + sampleAt(i1, 1) * t
                } else {
                    l
                }
                out[i * STEREO_CHANNELS] = clampSample(l.toInt())
                out[i * STEREO_CHANNELS + 1] = clampSample(r.toInt())
            }
            return out
        }

        private fun encodeAac(pcm: ShortArray, target: File): Boolean {
            var codec: MediaCodec? = null
            try {
                val format = MediaFormat
                    .createAudioFormat(MIME_AUDIO, SAMPLE_RATE, STEREO_CHANNELS)
                    .apply {
                        setInteger(
                            MediaFormat.KEY_AAC_PROFILE,
                            MediaCodecInfo.CodecProfileLevel.AACObjectLC
                        )
                        setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 256 * 1024)
                    }
                codec = MediaCodec.createEncoderByType(MIME_AUDIO)
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()

                val pcmBytes = ByteArray(pcm.size * 2)
                pcmBytes.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(pcm)

                FileOutputStream(target).use { fos ->
                    val bufferInfo = MediaCodec.BufferInfo()
                    var offset = 0
                    var inputDone = false
                    var outputDone = false

                    while (!outputDone) {
                        if (!inputDone) {
                            val inputIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                            if (inputIndex >= 0) {
                                val buffer = codec.getInputBuffer(inputIndex)
                                if (buffer == null || buffer.capacity() <= 0) {
                                    codec.queueInputBuffer(
                                        inputIndex, 0, 0, 0,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                    inputDone = true
                                } else {
                                    buffer.clear()
                                    val remaining = pcmBytes.size - offset
                                    val chunk = min(buffer.capacity(), remaining)
                                    if (chunk <= 0) {
                                        codec.queueInputBuffer(
                                            inputIndex, 0, 0, 0,
                                            MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                        )
                                        inputDone = true
                                    } else {
                                        buffer.put(pcmBytes, offset, chunk)
                                        codec.queueInputBuffer(inputIndex, 0, chunk, 0, 0)
                                        offset += chunk
                                    }
                                }
                            }
                        }

                        val outputIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                        when {
                            outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                            outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                            outputIndex >= 0 -> {
                                val buffer = codec.getOutputBuffer(outputIndex)
                                val isConfig =
                                    (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                                if (buffer != null && bufferInfo.size > 0 && !isConfig) {
                                    fos.write(buffer, bufferInfo.offset, bufferInfo.size)
                                }
                                codec.releaseOutputBuffer(outputIndex, false)
                                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                    outputDone = true
                                }
                            }
                        }
                    }
                }
                return target.length() > 0
            } catch (_: Throwable) {
                target.delete()
                return false
            } finally {
                try {
                    codec?.stop()
                } catch (_: Throwable) {
                }
                try {
                    codec?.release()
                } catch (_: Throwable) {
                }
            }
        }

        private fun clampSample(value: Int): Short = when {
            value > Short.MAX_VALUE -> Short.MAX_VALUE
            value < Short.MIN_VALUE -> Short.MIN_VALUE
            else -> value.toShort()
        }

        private fun decodePng(bytes: ByteArray): Bitmap {
            scratch?.recycle()
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: throw IllegalStateException("could not decode frame PNG")
        }

        private fun stopMuxer() {
            try {
                if (muxerStarted) {
                    muxer?.stop()
                    muxerStarted = false
                }
            } catch (_: Throwable) {
            }
            try {
                muxer?.release()
            } catch (_: Throwable) {
            }
            muxer = null
        }

        private fun releaseEncoder() {
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
            surface = null
            try {
                encoder?.stop()
            } catch (_: Throwable) {
            }
            try {
                encoder?.release()
            } catch (_: Throwable) {
            }
            encoder = null
            scratch?.recycle()
            scratch = null
        }

        fun release() {
            releaseEncoder()
            stopMuxer()
            audioFile?.delete()
            audioFile = null
        }
    }
}