from nestlo_services.gateway import listen_addresses


def test_listen_accepts_string_or_list():
    assert listen_addresses({"gateway": {"listen": "127.0.0.1"}}) == ["127.0.0.1"]
    assert listen_addresses({"gateway": {"listen": ["127.0.0.1", "10.200.0.1"]}}) == ["127.0.0.1", "10.200.0.1"]


def test_serves_on_every_listen_address(make_gateway):
    gw = make_gateway(gateway={"listen": ["127.0.0.1", "127.0.0.2"], "port": 0})
    assert gw.port > 0
