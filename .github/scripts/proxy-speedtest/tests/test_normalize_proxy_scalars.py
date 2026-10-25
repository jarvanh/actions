"""normalize_proxy_scalars：导出前把 port / alterId 统一成整数。

背景（2026-10-25）：上游订阅常把端口写成 `port: '443'`（字符串），严格类型的客户端
（Egern 要求 port 为 integer）会整条节点 decode 失败，并报出「位于第 2 行第 3 列」
这类指向节点首键的假 YAML 错误。导出端统一转 int 后，Egern 可直接加载。
"""
import yaml

from speedtest_common import normalize_proxy_scalars


def test_string_port_becomes_int():
    proxy = {'name': 'n1', 'type': 'vless', 'server': 'a.example.com', 'port': '443'}
    assert normalize_proxy_scalars(proxy)['port'] == 443


def test_int_port_untouched():
    proxy = {'name': 'n1', 'port': 8443}
    assert normalize_proxy_scalars(proxy)['port'] == 8443


def test_alter_id_string_becomes_int():
    proxy = {'name': 'n1', 'type': 'vmess', 'port': '443', 'alterId': '0'}
    out = normalize_proxy_scalars(proxy)
    assert out['port'] == 443
    assert out['alterId'] == 0


def test_non_numeric_port_kept_as_is():
    proxy = {'name': 'n1', 'port': 'auto'}
    assert normalize_proxy_scalars(proxy)['port'] == 'auto'


def test_original_dict_not_mutated():
    proxy = {'name': 'n1', 'port': '443'}
    normalize_proxy_scalars(proxy)
    assert proxy['port'] == '443'


def test_yaml_dump_emits_unquoted_port():
    proxy = normalize_proxy_scalars({'name': 'n1', 'type': 'vless', 'port': '443'})
    text = yaml.safe_dump({'proxies': [proxy]}, allow_unicode=True, sort_keys=False)
    assert "port: 443" in text
    assert "port: '443'" not in text
