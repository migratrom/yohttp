import YoHTTP

enum TLSFixtures {
    static let key = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgfGqOfHluAX4mpwVE
        Yw50sNCjPprz8d3qQinOobMSCPehRANCAAQFgjfrM4HtOH0pOtTjHMAZH3MT9KHE
        X+nD4cGTyvUPwVB1+bSQ+5x0GxcpA0QZMcawMmd2B3PvQaJGmQE+9cz2
        -----END PRIVATE KEY-----
        """

    static let cert = """
        -----BEGIN CERTIFICATE-----
        MIIBmzCCAUGgAwIBAgIUU+2oBXtQUWUOg2l52muvGAwGBVEwCgYIKoZIzj0EAwIw
        FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDkwNDExMzczMloYDzIxMjYwODEx
        MTEzNzMyWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
        PQMBBwNCAAQFgjfrM4HtOH0pOtTjHMAZH3MT9KHEX+nD4cGTyvUPwVB1+bSQ+5x0
        GxcpA0QZMcawMmd2B3PvQaJGmQE+9cz2o28wbTAdBgNVHQ4EFgQUP1zb3xjUfHQg
        gY/illy3qXimlWUwHwYDVR0jBBgwFoAUP1zb3xjUfHQggY/illy3qXimlWUwDwYD
        VR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZI
        zj0EAwIDSAAwRQIgbJDvO5o7jH5EcJeJ5vJAMRsFyOI+3YdVynIkNgSNDfwCIQCp
        FWGDQs7lvldZyNEyKFlSsa+G9M+LZB3ca2G5MCqFPQ==
        -----END CERTIFICATE-----
        """

    static let otherKey = """
        -----BEGIN EC PRIVATE KEY-----
        MHcCAQEEIINeDe9mD0MKPiPQmhBXE514cTmUGVhLgpVWtcxpCe7soAoGCCqGSM49
        AwEHoUQDQgAEXguWIBaym5FLUE55KwnZTswX+7PwIqSAFfbzhdYpJrLJLu1h3gcW
        +Y19ywh2EaAohmBGASd5qkQpxvQ62aLpiw==
        -----END EC PRIVATE KEY-----
        """

    static var valid: TLS { TLS(key: key, cert: cert) }
}
