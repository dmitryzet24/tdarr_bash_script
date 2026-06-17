#!/bin/bash 

# --- АВТОМАТИЧЕСКИЙ ПОИСК БИНАРНИКОВ FFMPEG/FFPROBE ВНУТРИ TDARR --- 
TDARR_FFMPEG=$(find /app -type f -name "ffmpeg" -print -quit 2>/dev/null) 
if [[ -n "$TDARR_FFMPEG" ]]; then 
    TDARR_BIN_DIR=$(dirname "$TDARR_FFMPEG") 
    export PATH="$TDARR_BIN_DIR:$PATH" 
fi 

# --- НАСТРОЙКИ ЛОГОВ --- 
ERROR_LOG="/tmp/tdarr_script_error.log" 
PROCESSED_LOG="/tmp/tdarr_script_processed.log" 

# --- РАЗБОР АРГУМЕНТОВ (Железобетонный фикс пробелов) --- 
IN_FILE="" 
OUT_FILE="" 

# --- ДЕБАГ ВХОДЯЩИХ АРГУМЕНТОВ ---
echo "=== ДЕБАГ: Всего аргументов получено: $# ===" >> /tmp/tdarr_args_debug.log
echo "Полная строка аргументов (\$*): $*" >> /tmp/tdarr_args_debug.log

count=1
for arg in "$@"; do
    echo "Аргумент №$count: '$arg'" >> /tmp/tdarr_args_debug.log
    ((count++))
done
echo "=========================================" >> /tmp/tdarr_args_debug.log
# --- КОНЕЦ ДЕБАГА ---

 while [[ $# -gt 0 ]]; do 
   case "$1" in 
       -i) 
            # Заменяем HTML-слэши и сохраняем входной файл 
            CLEAN_PATH=$(echo "$2") 
            IN_FILE=""$CLEAN_PATH"" 
            shift 2 
            ;; 
        -o) 
            shift 
            # Забираем ВТОРУЮ ЧАСТЬ строки целиком, склеивая все разбитые пробелами аргументы 
            REST_OF_ARGS="$*" 
            # Отрезаем всё, что может идти после расширения .mkv или .mp4 (на случай других флагов) 
            CLEAN_OUT=$(echo "$REST_OF_ARGS" | sed 's/&#x2F;/\//g') 
            OUT_FILE="$CLEAN_OUT" 
            break 
            ;; 
        *) 
            shift 
            ;; 
    esac 
 done 

# АВАРИЙНЫЙ ВЫХОД: если пути пустые 
if [[ -z "$IN_FILE" || -z "$OUT_FILE" ]]; then 
    echo "[ОШИБКА] Скрипт получил пустые пути!" 
    echo "Вход: '$IN_FILE'" 
    echo "Выход: '$OUT_FILE'" 
    exit 1 
fi 
if [[ ! -f "$IN_FILE" ]]; then 
    echo "[ОШИБКА] Входной файл не найден: $IN_FILE" 
    exit 1 
fi 
TARGET_BASE=$(basename "$IN_FILE" | sed 's/\.[^.]*$//') 
timestamp=$(date "+%Y-%m-%d %H:%M:%S") 
echo "-----------------------------------------------------------------------" 
echo "ОБРАБОТКА TDARR FLOW: $TARGET_BASE" 
echo "Вход  (оригинал): $IN_FILE" 
echo "Выход (в кэш):    $OUT_FILE" 
if ! command -v ffprobe &> /dev/null; then 
    echo "[ОШИБКА] ffprobe не найден внутри контейнера Tdarr!" 
    exit 1 
fi 
# --- ПРОВЕРКА НА ПРОПУСК --- 
# Пропускаем файл если: формат MKV и все аудиодорожки уже стерео/моно (≤ 2 канала) 
IN_EXT="${IN_FILE##*.}" 
IN_EXT_LOWER="${IN_EXT,,}" 
if [[ "$IN_EXT_LOWER" == "mkv" ]]; then 
    max_channels=$(ffprobe -v error -select_streams a -show_entries stream=channels -of csv=p=0 "$IN_FILE" | tr -d '[:space:]' | tr ',' '\n' | sort -nr | head -n1)
    if [[ -n "$max_channels" && "$max_channels" =~ ^[0-9]+$ && "$max_channels" -le 2 ]]; then 
        echo "  [ПРОПУСК] Файл уже в формате MKV с дорожками стерео/моно (макс. каналов: $max_channels)." 
        echo "[$timestamp] Пропущен (уже стерео MKV): $TARGET_BASE" >> "$PROCESSED_LOG" 
        if [[ "$IN_FILE" != "$OUT_FILE" ]]; then 
            cp "$IN_FILE" "$OUT_FILE" 
        fi 
        exit 0 
    fi 
fi 
# --- 1. СБОР ДАННЫХ ОБ АУДИОПОТОКАХ --- 
mapfile -t audio_info < <(ffprobe -v error \
	-select_streams a \
	-show_entries stream=codec_name,channels:stream_tags=language,title \
	-of csv=p=0:s=\| "$IN_FILE" | tr -d '"') 
audio_args=() 
out_idx=0 
has_valid_audio=false
# FIX: ассоциативный массив вместо eval для счётчиков языков 
declare -A lang_counter 
audio_stream_num=0
echo "  Анализ аудио дорожек..." 
for line in "${audio_info[@]}"; do 
    # Поля: index|codec_name|channels|language|title 
    IFS='|' read -r codec channels lang title <<<"$line"

    current_audio_idx=$audio_stream_num
    (( audio_stream_num++ ))
    l_title="${title,,}" 
    l_lang="${lang,,}" 
    # --- Фильтрация одноголосых и авторских переводов (дубляжи НЕ трогаем) --- 
    if [[ "$l_title" =~(одноголосый|авторский|одн\.|авт\.|володар|гаврилов|живов|михалев|сербин|королев|санаев|карцев|doctor\.jet|avo|пучков|гоблин) ]]; then
        echo "    - Пропуск (одноголосый/авторский): поток $idx ($title)"
        continue 
    fi 
    # --- Фильтрация дорожек с комментариями --- 
    if [[ "$l_title" =~ (commentary|комментар) ]]; then 
        echo "    - Пропуск (комментарии): поток $idx ($title)" 
        continue 
    fi 

    # --- Определение языка --- 
    if [[ "$l_lang" =~ ^(rus|ru)$ ]]; then
        r_lang_text="Russian"

    elif [[ "$l_lang" =~ ^(eng|en)$ ]]; then
        r_lang_text="English"

    elif [[ "$l_lang" =~ ^(ukr|uk|ua)$ ]]; then
        r_lang_text="Ukrainian"

    elif [[ "$l_lang" =~ ^(spa|es)$ ]]; then
        r_lang_text="Spanish"

    elif [[ "$l_lang" =~ ^(fra|fre|fr)$ ]]; then
        r_lang_text="French"

    elif [[ "$l_lang" =~ ^(deu|ger|de)$ ]]; then
        r_lang_text="German"

    elif [[ "$l_lang" =~ ^(ita|it)$ ]]; then
        r_lang_text="Italian"

    elif [[ "$l_lang" =~ ^(por|pt)$ ]]; then
        r_lang_text="Portuguese"

    elif [[ "$l_lang" =~ ^(pol|pl)$ ]]; then
        r_lang_text="Polish"

    elif [[ "$l_lang" =~ ^(jpn|ja)$ ]]; then
        r_lang_text="Japanese"

    elif [[ "$l_lang" =~ ^(kor|ko)$ ]]; then
        r_lang_text="Korean"

    elif [[ "$l_lang" =~ ^(zho|chi|zh)$ ]]; then
        r_lang_text="Chinese"

    elif [[ "$l_lang" =~ ^(ces|cze|cs)$ ]]; then
        r_lang_text="Czech"

    elif [[ "$l_lang" =~ ^(nld|dut|nl)$ ]]; then
        r_lang_text="Dutch"

    elif [[ "$l_lang" =~ ^(swe|sv)$ ]]; then
        r_lang_text="Swedish"

    elif [[ "$l_lang" =~ ^(nor|no)$ ]]; then
        r_lang_text="Norwegian"

    elif [[ "$l_lang" =~ ^(dan|da)$ ]]; then
        r_lang_text="Danish"

    elif [[ "$l_lang" =~ ^(fin|fi)$ ]]; then
        r_lang_text="Finnish"

    elif [[ "$l_lang" =~ ^(hun|hu)$ ]]; then
        r_lang_text="Hungarian"

    elif [[ "$l_lang" =~ ^(ron|rum|ro)$ ]]; then
        r_lang_text="Romanian"

    elif [[ "$l_lang" =~ ^(tur|tr)$ ]]; then
        r_lang_text="Turkish"

    elif [[ "$l_lang" =~ ^(ara|ar)$ ]]; then
        r_lang_text="Arabic"

    elif [[ "$l_lang" =~ ^(hin|hi)$ ]]; then
        r_lang_text="Hindi"

    else
        r_lang_text="Audio"
    fi

    # FIX: счётчик дубликатов через ассоциативный массив 
    lang_counter["$l_lang"]=$(( ${lang_counter["$l_lang"]:-0} + 1 )) 
    current_count=${lang_counter["$l_lang"]} 
    
    # --- Формирование названия дорожки --- 
    # Очищаем title от технических тегов, сохраняя студию/автора 
    r_author="" 
    if [[ -n "$title" ]]; then 
        r_author=$(echo "$title" | sed -E 's/([0-9]+\.[0-9]+|Ch|kHz|kbps|DTS|DD|AC3|MPEG|AAC)//gi' | sed -E 's/[[:space:][:punct:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g') 
    fi
    # Убираем дубли языка из названия
    if [[ "$l_lang" =~ ^(rus|ru)$ ]]; then
        r_author=$(echo "$r_author" | sed -E 's/^Russian[[:space:]]+//i;s/^Русский[[:space:]]+//i')
    elif [[ "$l_lang" =~ ^(eng|en)$ ]]; then
        r_author=$(echo "$r_author" | sed -E 's/^English[[:space:]]+//i;s/^Английский[[:space:]]+//i')
    fi

    # Вычисляем disposition только для прошедших фильтрацию дорожек
    if [[ "$l_lang" == "eng" || "$l_lang" == "en" ]]; then
        disp="+default"
    else
        disp="0"
    fi

    # Настраиваем параметры в зависимости от исходных каналов
    if [[ -n "$channels" && "$channels" -le 2 ]]; then
        # Для моно/стерео оставляем родное количество каналов в тексте
        if [[ "$channels" -eq 1 ]]; then
            ch_text="1.0"
        else
            ch_text="2.0"
        fi

        # Генерируем название
        if [[ -n "$r_author" && ! "${r_author,,}" =~ ^(russian|english|audio)$ ]]; then 
            track_title="$ch_text ($r_lang_text - $r_author)" 
        elif [[ $current_count -gt 1 ]]; then 
            track_title="$ch_text ($r_lang_text - Track $current_count)" 
        else 
            track_title="$ch_text ($r_lang_text)" 
        fi 

        # Копируем без изменений
        audio_args+=(
            "-map"              "0:a:$current_audio_idx"
            "-c:a:$out_idx"     "copy"
            "-metadata:s:a:$out_idx" "title=$track_title"
            "-disposition:a:$out_idx" "$disp"
        )
        echo "    + [КОПИРОВАНИЕ] поток $current_audio_idx ($codec, ${channels}ch) → сохраняем без изменений как «$track_title»"
    else
        # Многоканал принудительно станет 2.0
        ch_text="2.0"

        # Генерируем название
        if [[ -n "$r_author" && ! "${r_author,,}" =~ ^(russian|english|audio)$ ]]; then 
            track_title="$ch_text ($r_lang_text - $r_author)" 
        elif [[ $current_count -gt 1 ]]; then 
            track_title="$ch_text ($r_lang_text - Track $current_count)" 
        else 
            track_title="$ch_text ($r_lang_text)" 
        fi 

        # Сжимаем в AAC Stereo
        audio_args+=(
            "-map"              "0:a:$current_audio_idx"
            "-c:a:$out_idx"     "aac"
            "-b:a:$out_idx"     "256k"
            "-ac:a:$out_idx"      "2"
            "-metadata:s:a:$out_idx" "title=$track_title"
            "-disposition:a:$out_idx" "$disp"
        )
        echo "    + [AAC 2.0 / 256k] поток $current_audio_idx ($codec, ${channels}ch) → «$track_title»"
    fi
    has_valid_audio=true
    (( out_idx++ ))
done

# Если все дорожки были отфильтрованы — оставляем первую в стерео 
if [[ "$has_valid_audio" == false ]]; then 
    echo "  [ВНИМАНИЕ] Все дорожки отфильтрованы. Оставляю первую дорожку в стерео." 
    audio_args+=( 
        "-map"          "0:a:0" 
        "-c:a:0"        "aac" 
        "-b:a:0"        "256k" 
        "-ac:0"         "2" 
        "-disposition:a:0" "0" 
    ) 
fi 
# --- 2. СБОР ДАННЫХ О СУБТИТРАХ --- 
# FIX: собираем только субтитры с кодеками, совместимыми с MKV/SRT
#      PGS (hdmv_pgs_subtitle) и DVDSUB (dvd_subtitle) пропускаем — они не конвертируются в SRT без OCR. 
mapfile -t sub_info < <(ffprobe -v error -select_streams s -show_entries stream=index,codec_name -of csv=p=0:s=\| "$IN_FILE" | tr -d '"') 
sub_args=()
echo "  Анализ субтитров..." 
for line in "${sub_info[@]}"; do 
    IFS='|' read -r s_idx s_codec <<<"$line" 
    s_codec_lower="${s_codec,,}" 
    case "$s_codec_lower" in 
        subrip|srt|ass|ssa|webvtt|mov_text|text|hdmv_text_subtitle) 
            sub_args+=("-map" "0:$s_idx") 
            echo "    + Субтитры: поток $s_idx ($s_codec) → копируем" 
            ;; 
        hdmv_pgs_subtitle|dvd_subtitle|xsub) 
            echo "    - Субтитры: поток $s_idx ($s_codec) → пропуск (требует OCR)" 
            ;; 
        *) 
            echo "    - Субтитры: поток $s_idx ($s_codec) → пропуск (неизвестный кодек)" 
            ;; 
    esac 
done 
if [[ ${#sub_args[@]} -gt 0 ]]; then 
    sub_args+=("-c:s" "copy") 
fi 
# --- 3. ОПРЕДЕЛЕНИЕ ВЫХОДНОГО ФОРМАТА --- 
OUT_EXT="${OUT_FILE##*.}" 
OUT_EXT_LOWER="${OUT_EXT,,}" 
# FIX: -movflags +faststart только для MP4, для MKV не нужен и вызывает warning 
extra_args=() 
if [[ "$OUT_EXT_LOWER" == "mp4" ]]; then 
    extra_args+=("-movflags" "+faststart") 
fi 

# --- 4. ЗАПУСК FFMPEG С ТРАНСЛЯЦИЕЙ ЛОГОВ ---
tmp_err=$(mktemp)

echo "  Запуск обработки через FFmpeg..."

# Запускаем FFmpeg. Перенаправляем стандартный вывод в stderr (через >&2), 
# чтобы Tdarr видел строчки прогресса в реальном времени, 
# одновременно дублируя ошибки в файл tmp_err.
echo "================ CMD ================"
printf '%q ' ffmpeg -y \
    -i "$IN_FILE" \
    -map 0:v? -c:v copy \
    "${audio_args[@]}" \
    "${sub_args[@]}" \
    "${extra_args[@]}" \
    -progress pipe:2 \
    -stats \
    -loglevel info \
    "$OUT_FILE"

echo
echo "====================================="

ffmpeg -y \
    -i "$IN_FILE" \
    -map 0:v? -c:v copy \
    "${audio_args[@]}" \
    "${sub_args[@]}" \
    "${extra_args[@]}" \
    -progress pipe:2 \
    -stats \
    -loglevel info \
    "$OUT_FILE" \
    2> >(tee "$tmp_err" >&2)

# Сохраняем статус выхода ffmpeg
FFMPEG_STATUS=$?

echo "FFMPEG_STATUS=$FFMPEG_STATUS"

if [[ -f "$OUT_FILE" ]]; then
    ls -lh "$OUT_FILE"
else
    echo "OUT_FILE NOT FOUND: $OUT_FILE"
fi

if [[ $FFMPEG_STATUS -eq 0 && -s "$OUT_FILE" ]]; then
    echo "  [SUCCESS] Файл успешно создан в кэше Tdarr."
    echo "[$timestamp] Успешно: $TARGET_BASE" >> "$PROCESSED_LOG"
    rm -f "$tmp_err"
    exit 0
else
    echo "  [ERROR] Ошибка ffmpeg при обработке. Подробности в логе."
    echo "[$timestamp] ОШИБКА: $TARGET_BASE" >> "$ERROR_LOG"
    cat "$tmp_err" >> "$ERROR_LOG"
    echo "------------------------------------------------" >> "$ERROR_LOG"
    rm -f "$tmp_err"
    exit 1
fi
