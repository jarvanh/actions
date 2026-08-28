# 从 OpenList 数据库（x_storages 表）读取指定挂载的 addition JSON。
# 用法: python3 get_storage_addition.py <db_path> <mount_path>
# 输出: 成功时 stdout 为 addition JSON 原文；诊断信息走 stderr。
# 退出码: 0 成功 / 1 参数缺失 / 3 addition 为空 / 4 挂载不存在 / 5 sqlite 读取失败
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
