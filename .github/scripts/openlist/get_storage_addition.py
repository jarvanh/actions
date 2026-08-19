import sqlite3
import sys

def main():
    if len(sys.argv) < 3:
        print("Usage: python get_storage_addition.py <db_path> <mount_path>", file=sys.stderr)
        sys.exit(1)
        
    db = sys.argv[1]
    mount = sys.argv[2]
    
    def norm(p):
        return (p or "").strip().strip("/")
        
    def dump(con):
        rows = con.execute("SELECT mount_path, addition FROM x_storages").fetchall()
        for mp, add in rows:
            if norm(mp) == norm(mount):
                if add:
                    print(add)
                    sys.exit(0)
                print(f"目标 {mount} 的 addition 为空", file=sys.stderr)
                sys.exit(3)
        names = ", ".join(norm(mp) or "?" for mp, _ in rows) or "(空表)"
        print(f"x_storages 中无 {mount}; 现有: {names}", file=sys.stderr)
        sys.exit(4)
        
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        dump(con)
    except sqlite3.Error as e:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
            dump(con)
        except sqlite3.Error as e2:
            print(f"sqlite 读取失败: {e}; immutable 重试: {e2}", file=sys.stderr)
            sys.exit(5)

if __name__ == "__main__":
    main()
