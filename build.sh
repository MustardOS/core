#!/bin/sh

printf "\nMURCB - muOS RetroArch Core Builder\n"

# Show 'build.sh' USAGE options
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

# Initialise all options to 0
PURGE=0
BUILD_ALL=0
BUILD_CORES=""
OPTION_SPECIFIED=0
UPDATE=0
STORAGE_POINTER=x

# If argument '-p' or '--purge' provided, set PURGE=1
if [ "$#" -gt 0 ]; then
	case "$1" in
		-p | --purge)
			PURGE=1
			shift
			;;
	esac
fi

# If no argument(s) provided show USAGE
if [ "$#" -eq 0 ]; then
	USAGE
fi

# Check for remaining arguments and set appropriate options
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

# Confirm a valid argument was provided, else show USAGE
[ "$OPTION_SPECIFIED" -eq 0 ] && USAGE

# Initialise directory variables
BASE_DIR=$(pwd)
CORE_CONFIG="core.json"
BUILD_DIR="$BASE_DIR/build"
CORES_DIR="$BASE_DIR/cores"
PATCH_DIR="$BASE_DIR/patch"

# Create an update zip containing all cores
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

# Detect proper aarch64 objcopy command.
if command -v aarch64-linux-gnu-objcopy >/dev/null 2>&1; then
    OBJCOPY=aarch64-linux-gnu-objcopy
elif command -v aarch64-linux-objcopy >/dev/null 2>&1; then
    OBJCOPY=aarch64-linux-objcopy
else
    printf "Error: Neither aarch64-linux-gnu-objcopy nor aarch64-linux-objcopy found\n" >&2
    exit 1
fi

# Detect proper aarch64 strip command.
if command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    STRIP=aarch64-linux-gnu-strip
elif command -v aarch64-linux-strip >/dev/null 2>&1; then
    STRIP=aarch64-linux-strip
elif command -v strip >/dev/null 2>&1; then
    STRIP=strip
else
    printf "Error: No suitable strip command found\n" >&2
    exit 1
fi

# Check for other required commands
for CMD in file git jq make patch pv readelf zip; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        printf "Error: Missing required command '%s'\n" "$CMD" >&2
        exit 1
    fi
done

# Create required directories
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
    # Extract the commands as separate lines from the JSON.
    CMD=$(printf '%s\n' "$2" | jq -r '.[]')
    printf "Running:\n%s\n" "$CMD"
    # Feed the commands into sh via a here-document so they run in one session.
    sh <<EOF
$CMD
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

# Load the cache file
CACHE_FILE="$BASE_DIR/cache.json"
if [ ! -f "$CACHE_FILE" ]; then
    echo "{}" > "$CACHE_FILE"
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

	# Optional branch/commit hash
	BRANCH=$(echo "$MODULE" | jq -r '.branch // ""')

	# Optional keys
	PRE_MAKE=$(echo "$MODULE" | jq -r '.commands["pre-make"] // []')
	POST_MAKE=$(echo "$MODULE" | jq -r '.commands["post-make"] // []')

	CORE_DIR="$CORES_DIR/$DIR"

	printf "Processing: %s\n\n" "$NAME"

	# Get cached hash
	CACHED_HASH=$(jq -r --arg name "$NAME" '.[$name] // ""' "$CACHE_FILE")

	# Get remote hash before cloning, modified for commit hash support:
	if [ -n "$BRANCH" ]; then
	    if echo "$BRANCH" | grep -qE '^[0-9a-f]{7,40}$'; then
	         REMOTE_HASH="$BRANCH"
	    else
	         REMOTE_HASH=$(git ls-remote "$SOURCE" "refs/heads/$BRANCH" | cut -c 1-7)
	    fi
	else
	    REMOTE_HASH=$(git ls-remote "$SOURCE" HEAD | cut -c 1-7)
	fi

	if [ -z "$REMOTE_HASH" ]; then
		printf "Failed to get remote hash for '%s'\n" "$NAME" >&2
		continue
	fi

	printf "Remote hash: %s\n" "$REMOTE_HASH"
	printf "Cached hash: %s\n" "$CACHED_HASH"

	if [ "$CACHED_HASH" = "$REMOTE_HASH" ] && [ "$PURGE" -eq 0 ] && [ -f "$OUTPUT" ]; then
		printf "Core '%s' is up to date (hash: %s). Skipping build.\n" "$NAME" "$REMOTE_HASH"
		continue
	fi

	if [ "$PURGE" -eq 1 ]; then
		printf "Purging core '%s' directory\n" "$DIR"
		rm -rf "$CORE_DIR"
	fi

	BEEN_CLONED=0
	if [ ! -d "$CORE_DIR" ]; then
		printf "Core '%s' not found\n\n" "$DIR" "$SOURCE"
		# Modify clone command: if BRANCH is a commit hash, do not include -b.
		if [ -n "$BRANCH" ] && echo "$BRANCH" | grep -qE '^[0-9a-f]{7,40}$'; then
			GC_CMD="git clone --progress --quiet --recurse-submodules -j$(nproc) $SOURCE $CORE_DIR"
		else
			GC_CMD="git clone --progress --quiet --recurse-submodules -j$(nproc)"
			[ -n "$BRANCH" ] && GC_CMD="$GC_CMD -b $BRANCH"
			GC_CMD="$GC_CMD $SOURCE $CORE_DIR"
		fi
		eval "$GC_CMD" || {
			printf "Failed to clone %s\n" "$SOURCE" >&2
			continue
		}

		# If a commit hash was provided, checkout that commit after cloning.
		if [ -n "$BRANCH" ] && echo "$BRANCH" | grep -qE '^[0-9a-f]{7,40}$'; then
			cd "$CORE_DIR" || exit 1
			git checkout --detach "$BRANCH" || {
				printf "Failed to checkout commit %s in %s\n" "$BRANCH" "$CORE_DIR" >&2
				continue
			}
			cd - > /dev/null
		fi

		# Always update submodules even if the repo exists
		git submodule update --init --recursive || {
			printf "Failed to update submodules for %s\n" "$NAME" >&2
			RETURN_TO_BASE
			continue
		}

		# Update all submodules recursively
		git submodule update --init --recursive || {
			printf "Failed to update submodules for %s\n" "$SOURCE" >&2
			cd - > /dev/null  # Return to previous directory
			continue
		}
		# Return to previous directory
		cd - > /dev/null
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

    # Always update submodules even if the repo exists
    git submodule update --init --recursive || {
        printf "Failed to update submodules for %s\n" "$NAME" >&2
        RETURN_TO_BASE
        continue
    }

	if [ $BEEN_CLONED -eq 0 ]; then
		printf "Pulling latest changes for '%s'\n" "$NAME"
		git pull --quiet --recurse-submodules -j8 || {
			printf "Failed to pull latest changes for '%s'\n" "$NAME" >&2
			RETURN_TO_BASE
			continue
		}
	fi

	# Verify local hash matches remote hash after clone/pull
	LOCAL_HASH=$(git rev-parse --short HEAD | cut -c 1-7)
	if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
		printf "Warning: Local hash (%s) doesn't match remote hash (%s)\n" "$LOCAL_HASH" "$REMOTE_HASH" >&2
		RETURN_TO_BASE
		continue
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
	trap 'kill $PV_PID 2>/dev/null' EXIT

	MAKE_CMD="make V-1 -j$(nproc)"
	[ -n "$MAKE_FILE" ] && MAKE_CMD="$MAKE_CMD -f $MAKE_FILE"
	[ -n "$MAKE_ARGS" ] && MAKE_CMD="$MAKE_CMD $MAKE_ARGS"
	[ -n "$MAKE_TARGET" ] && MAKE_CMD="$MAKE_CMD $MAKE_TARGET"

	LOGFILE="$(dirname "$0")/build.log"
	START_TS=$(date +%s)

	# Run make; capture everything into build.log
	kill $PV_PID 2>/dev/null
	if make -j"$(nproc)" -f "$MAKE_FILE" $MAKE_ARGS $MAKE_TARGET >>"$LOGFILE" 2>&1; then
    	printf "\nBuild succeeded: %s\n" "$NAME"
    	jq --arg name "$NAME" --arg hash "$REMOTE_HASH" \
    	   '.[$name] = $hash' "$CACHE_FILE" >"$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
	else
    	printf "\nBuild FAILED: %s — see %s\n" "$NAME" "$LOGFILE" >&2
    	RETURN_TO_BASE
    	continue
	fi

	END_TS=$(date +%s)
	printf "Duration for '%s': %ds\n" "$NAME" "$((END_TS - START_TS))" >>"$LOGFILE"

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
			$STRIP -sx "$OUTPUT"
			printf "\nStripped debug symbols"
		fi

		# Check if the BuildID section is present
		if readelf -S "$OUTPUT" | grep -Fq '.note.gnu.build-id'; then
			$OBJCOPY --remove-section=.note.gnu.build-id "$OUTPUT"
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
