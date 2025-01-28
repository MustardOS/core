#!/bin/sh

printf "\nMURCB - muOS RetroArch Core Builder\n"

USAGE() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  -a, --all            Build all cores"
	echo "  -c, --core [cores]   Build specific cores (e.g., -c dosbox-pure sameboy)"
	echo "  -p, --purge          Purge cores directory before building"
	echo "  -u, --update         Combine all core archives into a single update archive"
	echo ""
	echo "Notes:"
	echo "  - Either -a, -c, or -u is required, but NOT together"
	echo "  - If -p is used, it MUST be the first argument"
	echo "  - The -u switch must have a storage pointer (e.g., -u mmc)"
	echo ""
	echo "Examples:"
	echo "  $0 -a"
	echo "  $0 -c dosbox-pure sameboy"
	echo "  $0 -p -a"
	echo "  $0 -p -c dosbox-pure sameboy"
	echo "  $0 -u mmc"
	echo ""
	exit 1
}

PURGE=0
BUILD_ALL=0
BUILD_CORES=""
OPTION_SPECIFIED=0
UPDATE=0
STORAGE_POINTER=x

if [ "$#" -gt 0 ]; then
	case "$1" in
		-p | --purge)
			PURGE=1
			shift
			;;
	esac
fi

if [ "$#" -eq 0 ]; then
	USAGE
fi

while [ "$#" -gt 0 ]; do
	case "$1" in
		-a | --all)
			[ "$OPTION_SPECIFIED" -ne 0 ] && USAGE
			BUILD_ALL=1
			OPTION_SPECIFIED=1
			shift
			;;
		-c | --core)
			[ "$OPTION_SPECIFIED" -ne 0 ] && USAGE
			OPTION_SPECIFIED=1
			shift
			if [ "$#" -eq 0 ]; then
				printf "Error: Missing cores\n\n" >&2
				USAGE
			fi
			BUILD_CORES="$*"
			break
			;;
		-u | --update)
			[ "$OPTION_SPECIFIED" -ne 0 ] && USAGE
			OPTION_SPECIFIED=1
			shift
			if [ "$#" -eq 0 ]; then
				printf "Error: Missing storage pointer\n\n" >&2
				USAGE
			fi
			STORAGE_POINTER="$1"
			shift
			[ -z "$STORAGE_POINTER" ] && {
				printf "Error: Invalid storage pointer\n"
				exit 1
			}
			UPDATE=1
			;;
		*)
			printf "Error: Unknown option '%s'\n" "$1" >&2
			USAGE
			;;
	esac
done

[ "$OPTION_SPECIFIED" -eq 0 ] && USAGE

BASE_DIR=$(pwd)
CORE_CONFIG="core.json"
BUILD_DIR="$BASE_DIR/build"
CORES_DIR="$BASE_DIR/cores"
PATCH_DIR="$BASE_DIR/patch"

UPDATE_ZIP() {
	UPDATE_ARCHIVE="muOS-RetroArch-Core_Update-$(date +"%Y-%m-%d_%H-%M").zip"
	TEMP_DIR="$(mktemp -d)"
	CORE_FOLDER="$TEMP_DIR/mnt/$STORAGE_POINTER/MUOS/core"

	if [ -z "$(ls "$BUILD_DIR"/*.zip 2>/dev/null)" ]; then
		printf "No ZIP files found in '%s'\n" "$BUILD_DIR" >&2
		rmdir "$TEMP_DIR"
		exit 1
	fi

	mkdir -p "$CORE_FOLDER"

	printf "Extracting all ZIP files from '%s' into '%s'\n" "$BUILD_DIR" "$CORE_FOLDER"

	for ZIP_FILE in "$BUILD_DIR"/*.zip; do
		printf "Unpacking '%s'...\n" "$(basename "$ZIP_FILE")"
		unzip -q "$ZIP_FILE" -d "$CORE_FOLDER" || {
			printf "Failed to unpack '%s'\n" "$(basename "$ZIP_FILE")" >&2
			rm -rf "$TEMP_DIR"
			exit 1
		}
	done

	printf "Creating consolidated update archive: %s\n" "$UPDATE_ARCHIVE"

	(cd "$TEMP_DIR" && zip -q -r "$BASE_DIR/$UPDATE_ARCHIVE" .) || {
		printf "Failed to create update archive\n" >&2
		rm -rf "$TEMP_DIR"
		exit 1
	}

	rm -rf "$TEMP_DIR"

	printf "Update archive created successfully: %s\n" "$BASE_DIR/$UPDATE_ARCHIVE"
	exit 0
}

[ "$UPDATE" -eq 1 ] && UPDATE_ZIP

for CMD in aarch64-linux-objcopy aarch64-linux-strip file git jq make patch pv readelf zip; do
	if ! command -v "$CMD" >/dev/null 2>&1; then
		printf "Error: Missing required command '%s'\n" "$CMD" >&2
		exit 1
	fi
done

mkdir -p "$BUILD_DIR"
mkdir -p "$CORES_DIR"

trap 'printf "\nAn error occurred. Returning to base directory.\n"; cd "$BASE_DIR"; exit 1' INT TERM

RETURN_TO_BASE() {
	cd "$BASE_DIR" || {
		printf "Failed to return to base directory\n" >&2
		exit 1
	}
}

RUN_COMMANDS() {
	printf "\nRunning '%s' commands\n" "$1"
	CMD_LIST=$(echo "$2" | jq -r '.[]')

	# Run through the list of given commands in the array and use an EOF to run them outside of this subshell
	while IFS= read -r CMD; do
		CMD=$(eval "echo \"$CMD\"")

		# Skip "Running" message for commands starting with 'printf'
		if ! echo "$CMD" | grep -qE '^printf'; then
			printf "Running: %s\n" "$CMD"
		fi
		eval "$CMD" || {
			printf "Command Failed: %s\n" "$CMD" >&2
			return 1
		}
	done <<EOF
$CMD_LIST
EOF
}

APPLY_PATCHES() {
	NAME="$1"
	CORE_DIR="$2"

	if [ -d "$PATCH_DIR/$NAME" ]; then
		printf "Applying patches from '%s' to '%s'\n" "$PATCH_DIR/$NAME" "$CORE_DIR"
		for PATCH in "$PATCH_DIR/$NAME"/*.patch; do
			[ -e "$PATCH" ] || continue
			printf "Applying patch: %s\n" "$PATCH"
			patch -d "$CORE_DIR" -p1 <"$PATCH" || {
				printf "Failed to apply patch: %s\n" "$PATCH" >&2
				return 1
			}
		done
		printf "\n"
	fi
}

# Get specific core names or process all cores given as arguments
if [ "$BUILD_ALL" -eq 0 ]; then
	CORES="$BUILD_CORES"
else
	CORES=$(jq -r 'keys[]' "$CORE_CONFIG")
fi

for NAME in $CORES; do
	printf "\n-------------------------------------------------------------------------\n"

	MODULE=$(jq -c --arg name "$NAME" '.[$name]' "$CORE_CONFIG")

	if [ -z "$MODULE" ] || [ "$MODULE" = "null" ]; then
		printf "Core '%s' not found in '%s'\n" "$NAME" "$CORE_CONFIG" >&2
		continue
	fi

	# Required keys
	DIR=$(echo "$MODULE" | jq -r '.directory')
	OUTPUT=$(echo "$MODULE" | jq -r '.output')
	SOURCE=$(echo "$MODULE" | jq -r '.source')
	SYMBOLS=$(echo "$MODULE" | jq -r '.symbols')

	# Make keys
	MAKE_FILE=$(echo "$MODULE" | jq -r '.make.file')
	MAKE_ARGS=$(echo "$MODULE" | jq -r '.make.args')
	MAKE_TARGET=$(echo "$MODULE" | jq -r '.make.target')

	# Verify required keys
	if [ -z "$DIR" ] || [ -z "$OUTPUT" ] || [ -z "$SOURCE" ] || [ -z "$MAKE_FILE" ] || [ -z "$SYMBOLS" ]; then
		printf "Missing required configuration keys for '%s' in '%s'\n" "$NAME" "$CORE_CONFIG" >&2
		continue
	fi

	# Optional branch
	BRANCH=$(echo "$MODULE" | jq -r '.branch // ""')

	# Optional keys
	PRE_MAKE=$(echo "$MODULE" | jq -c '.commands["pre-make"] // []')
	POST_MAKE=$(echo "$MODULE" | jq -c '.commands["post-make"] // []')

	CORE_DIR="$CORES_DIR/$DIR"

	printf "Processing: %s\n\n" "$NAME"

	if [ "$PURGE" -eq 1 ]; then
		printf "Purging core '%s' directory\n" "$DIR"
		rm -rf "$CORE_DIR"
	fi

	BEEN_CLONED=0
	if [ ! -d "$CORE_DIR" ]; then
		printf "Core '%s' not found\n\n" "$DIR" "$SOURCE"

		GC_CMD="git clone --progress --quiet --recurse-submodules -j$(nproc)"
		[ -n "$BRANCH" ] && GC_CMD="$GC_CMD -b $BRANCH"
		GC_CMD="$GC_CMD $SOURCE $CORE_DIR"

		eval "$GC_CMD" || {
			printf "Failed to clone %s\n" "$SOURCE" >&2
			continue
		}

		printf "\n"
		BEEN_CLONED=1
	fi

	APPLY_PATCHES "$NAME" "$CORE_DIR" || {
		printf "Failed to apply patches for %s\n" "$NAME" >&2
		continue
	}

	cd "$CORE_DIR" || {
		printf "Failed to enter directory %s\n" "$CORE_DIR" >&2
		continue
	}

	if [ $BEEN_CLONED -eq 0 ]; then
		printf "Pulling latest changes for '%s'\n" "$NAME"
		git pull --recurse-submodules -j8 || {
			printf "Failed to pull latest changes for '%s'\n" "$NAME" >&2
			RETURN_TO_BASE
			continue
		}
	fi

	if [ "$PRE_MAKE" != "[]" ]; then
		if ! RUN_COMMANDS "pre-make" "$PRE_MAKE"; then
			printf "Pre-make commands failed for %s\n" "$NAME" >&2
			RETURN_TO_BASE
			continue
		fi
	fi

	printf "Make Structure:"
	printf "\n\tFILE:\t%s" "$MAKE_FILE"
	printf "\n\tARGS:\t%s" "$MAKE_ARGS"
	printf "\n\tTARGET: %s\n" "$MAKE_TARGET"

	printf "\nBuilding '%s' (%s) ..." "$NAME" "$OUTPUT"

	(while :; do
		printf '.'
		sleep 1
	done) | pv -q -L 10 -N "Building $NAME" &

	PV_PID=$!

	MAKE_CMD="make -j$(nproc)"
	[ -n "$MAKE_FILE" ] && MAKE_CMD="$MAKE_CMD -f $MAKE_FILE"
	[ -n "$MAKE_ARGS" ] && MAKE_CMD="$MAKE_CMD $MAKE_ARGS"
	[ -n "$MAKE_TARGET" ] && MAKE_CMD="$MAKE_CMD $MAKE_TARGET"

	# Run the command
	if $MAKE_CMD >/dev/null 2>&1; then
		kill $PV_PID
		wait $PV_PID 2>/dev/null
		printf "\nBuild completed successfully for '%s'\n" "$NAME"
	else
		kill $PV_PID
		wait $PV_PID 2>/dev/null
		printf "\nBuild failed for '%s' using '%s'\n" "$NAME" "$MAKE_FILE" >&2
		RETURN_TO_BASE
		continue
	fi

	if [ "$POST_MAKE" != "[]" ]; then
		if ! RUN_COMMANDS "post-make" "$POST_MAKE"; then
			printf "Post-make commands failed for '%s'\n" "$NAME" >&2
			RETURN_TO_BASE
			continue
		fi
	fi

	if [ "$SYMBOLS" -eq 0 ]; then
		# Check if the output is not stripped already
		if file "$OUTPUT" | grep -q 'not stripped'; then
			aarch64-linux-strip -sx "$OUTPUT"
			printf "\nStripped debug symbols"
		fi

		# Check if the BuildID section is present
		if readelf -S "$OUTPUT" | grep -Fq '.note.gnu.build-id'; then
			aarch64-linux-objcopy --remove-section=.note.gnu.build-id "$OUTPUT"
			printf "\nRemoved BuildID section"
		fi
	fi

	printf "\nFile Information: %s\n" "$(file -b "$OUTPUT")"

	printf "\nMoving '%s' to '%s'\n" "$OUTPUT" "$BUILD_DIR"
	mv "$OUTPUT" "$BUILD_DIR" || {
		printf "Failed to move '%s' for '%s' to '%s'\n" "$OUTPUT" "$NAME" "$BUILD_DIR" >&2
		RETURN_TO_BASE
		continue
	}

	printf "\nIndexing and compressing '%s'\n" "$OUTPUT"

	cd "$BUILD_DIR" || {
		printf "Failed to enter directory %s\n" "$BUILD_DIR" >&2
		continue
	}

	INDEX=$(printf "%s %08x %s" "$(date +%Y-%m-%d)" "$(cksum "$OUTPUT" | awk '{print $1}')" "$OUTPUT.zip")

	[ -f "$OUTPUT.zip" ] && rm -f "$OUTPUT.zip"
	zip -q "$OUTPUT.zip" "$OUTPUT"
	rm "$OUTPUT"

	ESCAPED_OUTPUT_ZIP=$(printf "%s" "$OUTPUT.zip" | sed 's/[\\/&]/\\&/g')

	if [ -f .index-extended ]; then
		sed "/$ESCAPED_OUTPUT_ZIP/d" .index-extended >.index-extended.tmp
		mv .index-extended.tmp .index-extended
	else
		touch .index-extended
	fi
	echo "$INDEX" >>.index-extended

	if [ -f .index ]; then
		sed "/$ESCAPED_OUTPUT_ZIP/d" .index >.index.tmp
		mv .index.tmp .index
	else
		touch .index
	fi
	echo "$OUTPUT.zip" >>.index

	sort -k3 .index-extended -o .index-extended
	sort .index -o .index

	if [ "$PURGE" -eq 1 ]; then
		printf "\nPurging core directory: %s\n" "$CORE_DIR"
		rm -rf "$CORE_DIR"
	else
		printf "Cleaning build environment for '%s'\n" "$NAME"
		make clean >/dev/null 2>&1 || {
			printf "Clean failed or not required\n" >&2
		}
	fi

	RETURN_TO_BASE
done

(
	printf "<!DOCTYPE html>\n<html>\n<head>\n<title>MURCB - muOS RetroArch Core Builder</title>\n</head>\n<body>\n"
	printf "<pre style='font-size:2rem;margin-top:-5px;margin-bottom:-15px;'>MURCB - muOS RetroArch Core Builder</pre>\n"
	printf "<pre style='font-size:1rem;'>Currently only <span style='font-weight:800'>"
	printf "aarch64"
	printf "</span> builds for now!</pre>\n"
	printf "<hr>\n<pre>\n"
	[ -f "$BUILD_DIR/.index-extended" ] && cat "$BUILD_DIR/.index-extended" || printf "No cores available!\n"
	printf "</pre>\n</body>\n</html>\n"
) >"$BUILD_DIR/index.html"

printf "\n-------------------------------------------------------------------------\n"
printf "All successful core builds are in '%s'\n\n" "$BUILD_DIR"
