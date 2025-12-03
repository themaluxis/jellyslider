import os
import re

def is_turkish(text):
    turkish_chars = "ığüşöçİĞÜŞÖÇ"
    for char in turkish_chars:
        if char in text:
            return True
    return False

def scan_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading {filepath}: {e}")
        return

    found = False
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue

        # Check for comments
        if "//" in line or "/*" in line or line.startswith("*"):
            if is_turkish(line):
                print(f"{filepath}:{i+1}: {line}")
                found = True
                continue

        # Check for console logs and errors
        if "console." in line or "throw new Error" in line or "echo" in line:
             # Extract string content roughly
             strings = re.findall(r'["\'`](.*?)["\'`]', line)
             for s in strings:
                 if is_turkish(s):
                     print(f"{filepath}:{i+1}: {line}")
                     found = True
                     break
    return found

def main():
    exclude_dirs = {'.git', 'language', 'src/images', 'src/fonts', 'modules/hlsjs', 'modules/player/lyrics/jsmediatags'}
    extensions = {'.js', '.mjs', '.html', '.css', '.sh', '.bat'}

    for root, dirs, files in os.walk("."):
        # modify dirs in-place to exclude
        dirs[:] = [d for d in dirs if d not in exclude_dirs and os.path.join(root, d) not in ['./' + ed for ed in exclude_dirs]]

        for file in files:
            if any(file.endswith(ext) for ext in extensions):
                filepath = os.path.join(root, file)
                # Skip minified files
                if ".min." in filepath:
                    continue
                scan_file(filepath)

if __name__ == "__main__":
    main()
