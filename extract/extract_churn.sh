#!/bin/bash

# --- Configuration ---
# Set to true to include test files in analysis, false to exclude them
INCLUDE_TEST_FILES=false
# Only process subfolders within these specific directories
TARGET_DIRS=("modules/apps" "modules/dxp/apps")
# Array of required file extensions (used to ensure all are processed)
REQUIRED_EXTENSIONS=(".java" ".js" ".jsp" ".ts" ".tsx" ".css" ".scss")

# --- Pre-checks ---
if ! command -v git &> /dev/null; then
    echo "Error: Git is not installed or not in PATH."
    exit 1
fi

# Ensure at least one target directory exists
found_dir=false
for dir in "${TARGET_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        found_dir=true
        break
    fi
done

if [ "$found_dir" = false ]; then
    echo "Error: None of the target directories (${TARGET_DIRS[*]}) were found."
    echo "Please run this script from the root of your liferay-portal clone."
    exit 1
fi

# --- User Input ---
read -p "Enter the analysis quarter/tag (e.g., 'Q1-2024' or 'U143'): " ANALYSIS_QUARTER
read -p "Enter the previous local tag (older tag, e.g., '7.4.3.120-ga120'): " TAG1
read -p "Enter the newer local tag (newer tag, e.g., '7.4.3.121-ga121'): " TAG2

# Check if tags are valid local refs (^{} dereferences tag objects to their target commit)
if ! git rev-parse --quiet --verify "$TAG1^{}" > /dev/null 2>&1 || \
   ! git rev-parse --quiet --verify "$TAG2^{}" > /dev/null 2>&1; then
    echo "Error: One or both specified tags were not found locally."
    echo "Tip: Run 'git tag -l' to list available local tags."
    exit 1
fi

# --- DYNAMIC OUTPUT FILENAME GENERATION ---
# Sanitize quarter string (replace non-alphanumeric/hyphen/underscore with underscore)
SAFE_QUARTER=$(echo "$ANALYSIS_QUARTER" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_-]/-/g')
OUTPUT_FILE="${SAFE_QUARTER}-liferay_analysis.csv"

# --- Report Header (CSV Headers) ---
{
    echo "Quarter,Module,Total_FileCount,Total_LinesOfCode,Total_ModifiedFileCount,Total_Insertions,Total_Deletions,java_FileCount,java_LinesOfCode,java_ModifiedFileCount,java_Insertions,java_Deletions,js_FileCount,js_LinesOfCode,js_ModifiedFileCount,js_Insertions,js_Deletions,jsp_FileCount,jsp_LinesOfCode,jsp_ModifiedFileCount,jsp_Insertions,jsp_Deletions,ts_FileCount,ts_LinesOfCode,ts_ModifiedFileCount,ts_Insertions,ts_Deletions,tsx_FileCount,tsx_LinesOfCode,tsx_ModifiedFileCount,tsx_Insertions,tsx_Deletions,css_FileCount,css_LinesOfCode,css_ModifiedFileCount,css_Insertions,css_Deletions,scss_FileCount,scss_LinesOfCode,scss_ModifiedFileCount,scss_Insertions,scss_Deletions"
} > "$OUTPUT_FILE"

echo "Starting complete analysis for modules in ${TARGET_DIRS[*]}..."
echo "Analysis Quarter: $ANALYSIS_QUARTER"
echo "Comparing tags: $TAG1 to $TAG2"
echo "Results will be saved to: $OUTPUT_FILE"
echo "---"

# --- Main Loop: Iterate through each specified top-level directory ---
for parent_dir in "${TARGET_DIRS[@]}"; do
    
    # Iterate through each *subfolder* within the specified parent directory
    for module_dir in "$parent_dir"/*/; do
        
        # Only process if it is a directory
        if [ -d "$module_dir" ]; then
            
            # Remove leading path and trailing slash to get the relative folder path
            module_path=$(echo "$module_dir" | sed 's/\/$//')
            
            # Skip test directories if INCLUDE_TEST_FILES is false
            if [ "$INCLUDE_TEST_FILES" = false ]; then
                if [[ "$module_path" == *"-test" ]] || [[ "$module_path" == *"-tests" ]] || \
                   [[ "$module_path" == *"/test" ]] || [[ "$module_path" == *"/tests" ]]; then
                    echo "Skipping test directory: $module_path"
                    continue
                fi
            fi
            
            # 📢 PROGRESS ECHO
            echo "Processing: $module_path"
            
            # Initialize associative arrays for each extension
            declare -A file_counts
            declare -A loc_counts
            declare -A modified_counts
            declare -A insertion_counts
            declare -A deletion_counts
            
            # Initialize totals
            total_files=0
            total_loc=0
            total_modified=0
            total_insertions=0
            total_deletions=0
            
            # ------------------------------------------------------------------
            # Process each file type
            # ------------------------------------------------------------------
            
            for full_ext in "${REQUIRED_EXTENSIONS[@]}"; do
                
                # Get extension without the dot (e.g., "java", "js")
                ext=$(echo "$full_ext" | sed 's/\.//')
                
                # Initialize values for this extension
                file_counts[$ext]=0
                loc_counts[$ext]=0
                modified_counts[$ext]=0
                insertion_counts[$ext]=0
                deletion_counts[$ext]=0
                
                # ------------------------------------------------------------------
                # 1. Static Code Analysis (File Count and LOC)
                # ------------------------------------------------------------------
                
                # Build find command with conditional test file exclusions
                if [ "$INCLUDE_TEST_FILES" = false ]; then
                    STATIC_DATA=$(
                        find "$module_dir" -type f -name "*${full_ext}" \
                            ! -path "*/test/*" \
                            ! -path "*/tests/*" \
                            ! -path "*-test/*" \
                            ! -path "*-tests/*" \
                            ! -name "*Test.java" \
                            ! -name "*Test.js" \
                            ! -name "*Test.jsx" \
                            ! -name "*Test.ts" \
                            ! -name "*Test.tsx" \
                            ! -name "*.test.js" \
                            ! -name "*.test.jsx" \
                            ! -name "*.test.ts" \
                            ! -name "*.test.tsx" \
                            ! -name "*.spec.js" \
                            ! -name "*.spec.jsx" \
                            ! -name "*.spec.ts" \
                            ! -name "*.spec.tsx" | while read -r file; do
                            # Count lines of code
                            LOC=$(wc -l < "$file" 2>/dev/null | awk '{print $1}')
                            echo "$LOC"
                        done | awk '
                        {
                            file_count++;
                            loc_count+=$1;
                        }
                        END {
                            printf "%d %d\n", file_count, loc_count;
                        }'
                    )
                else
                    STATIC_DATA=$(
                        find "$module_dir" -type f -name "*${full_ext}" | while read -r file; do
                            # Count lines of code
                            LOC=$(wc -l < "$file" 2>/dev/null | awk '{print $1}')
                            echo "$LOC"
                        done | awk '
                        {
                            file_count++;
                            loc_count+=$1;
                        }
                        END {
                            printf "%d %d\n", file_count, loc_count;
                        }'
                    )
                fi
                
                # Parse the static data, defaulting to 0 if empty
                if [ ! -z "$STATIC_DATA" ]; then
                    read file_c loc_c <<< "$STATIC_DATA"
                else
                    file_c=0
                    loc_c=0
                fi
                
                file_counts[$ext]=${file_c:-0}
                loc_counts[$ext]=${loc_c:-0}
                
                # ------------------------------------------------------------------
                # 2. Git Metrics (Modified Files, Insertions, Deletions)
                # ------------------------------------------------------------------
                
                # Construct the pathspec for git diff
                PATHSPEC="$module_dir*${full_ext}"

                # Run git diff with conditional test file exclusions
                if [ "$INCLUDE_TEST_FILES" = false ]; then
                    # Exclude test files from git metrics
                    GIT_STATS=$(git diff --numstat "$TAG1" "$TAG2" -- "$PATHSPEC" 2>/dev/null | \
                        grep -v '/test/' | \
                        grep -v '/tests/' | \
                        grep -v '\-test/' | \
                        grep -v '\-tests/' | \
                        grep -v 'Test\.java$' | \
                        grep -v 'Test\.js$' | \
                        grep -v 'Test\.ts$' | \
                        grep -v 'Test\.tsx$' | \
                        grep -v '\.test\.js$' | \
                        grep -v '\.test\.jsx$' | \
                        grep -v '\.test\.ts$' | \
                        grep -v '\.test\.tsx$' | \
                        grep -v '\.spec\.js$' | \
                        grep -v '\.spec\.jsx$' | \
                        grep -v '\.spec\.ts$' | \
                        grep -v '\.spec\.tsx$' | \
                        awk '{insertions+=$1; deletions+=$2; files++} END {printf "%d files changed, %d insertions(+), %d deletions(-)\n", files, insertions, deletions}'
                    )
                else
                    # Include all files
                    GIT_STATS=$(git diff --shortstat "$TAG1" "$TAG2" -- "$PATHSPEC" 2>/dev/null)
                fi
                
                if [ ! -z "$GIT_STATS" ]; then
                    # Remove commas for easier parsing
                    GIT_STATS_PARSED=$(echo "$GIT_STATS" | sed 's/,//g')

                    # Extract metrics using grep and awk
                    MODIFIED_FILES=$(echo "$GIT_STATS_PARSED" | grep -o '[0-9]\+ files\? changed' | awk '{print $1}')
                    INSERTIONS=$(echo "$GIT_STATS_PARSED" | grep -o '[0-9]\+ insertions' | awk '{print $1}')
                    DELETIONS=$(echo "$GIT_STATS_PARSED" | grep -o '[0-9]\+ deletions' | awk '{print $1}')
                    
                    # Store values (default to 0 if not found)
                    modified_counts[$ext]=${MODIFIED_FILES:-0}
                    insertion_counts[$ext]=${INSERTIONS:-0}
                    deletion_counts[$ext]=${DELETIONS:-0}
                fi
                
                # Add to totals
                total_files=$((total_files + file_counts[$ext]))
                total_loc=$((total_loc + loc_counts[$ext]))
                total_modified=$((total_modified + modified_counts[$ext]))
                total_insertions=$((total_insertions + insertion_counts[$ext]))
                total_deletions=$((total_deletions + deletion_counts[$ext]))
                
            done # End of REQUIRED_EXTENSIONS loop
            
            # ------------------------------------------------------------------
            # 3. Write single row for this module with all metrics
            # ------------------------------------------------------------------
            
            # Build the CSV row
            CSV_ROW="\"$ANALYSIS_QUARTER\",\"$module_path\",$total_files,$total_loc,$total_modified,$total_insertions,$total_deletions"
            
            # Append each extension's metrics in the defined order
            for full_ext in "${REQUIRED_EXTENSIONS[@]}"; do
                ext=$(echo "$full_ext" | sed 's/\.//')
                CSV_ROW="$CSV_ROW,${file_counts[$ext]},${loc_counts[$ext]},${modified_counts[$ext]},${insertion_counts[$ext]},${deletion_counts[$ext]}"
            done
            
            # Write to output file
            echo "$CSV_ROW" >> "$OUTPUT_FILE"
            
            # Clean up associative arrays for next iteration
            unset file_counts
            unset loc_counts
            unset modified_counts
            unset insertion_counts
            unset deletion_counts

        fi
    done
done

echo -e "\n*** Analysis complete. Check the '$OUTPUT_FILE' for the complete CSV report. ***"