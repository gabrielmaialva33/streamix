defmodule Streamix.Library.CipherTest do
  use ExUnit.Case, async: true

  alias Streamix.Library.{Cipher, Key}

  setup do
    %{key: Key.generate(1), other: Key.generate(2)}
  end

  test "a sealed map opens with its key and context only", %{key: key, other: other} do
    blob = Cipher.seal_map(key, "watch_progress", %{"catalog_item_id" => 42})

    assert {:ok, %{"catalog_item_id" => 42}} = Cipher.open_map(key, "watch_progress", blob)
    assert :error = Cipher.open_map(key, "favorite", blob)
    assert :error = Cipher.open_map(other, "watch_progress", blob)

    # Same root, other owner: the user id is part of what was authenticated.
    assert :error = Cipher.open_map(Key.new(2, key.root), "watch_progress", blob)
  end

  test "any flipped byte makes the blob unreadable", %{key: key} do
    blob = Cipher.seal_map(key, "favorite", %{"catalog_item_id" => 7})

    for position <- 0..(byte_size(blob) - 1) do
      <<before::binary-size(^position), byte, rest::binary>> = blob
      tampered = <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>
      assert :error = Cipher.open_map(key, "favorite", tampered)
    end

    assert :error = Cipher.open_map(key, "favorite", "")
  end

  test "ciphertext length does not depend on what was sealed", %{key: key} do
    short = Cipher.seal_map(key, "favorite", %{"catalog_item_id" => 7, "content_type" => "movie"})

    long =
      Cipher.seal_map(key, "favorite", %{
        "catalog_item_id" => 123_456_789,
        "content_type" => "live_channel"
      })

    assert byte_size(short) == byte_size(long)
  end

  test "sealing twice gives different ciphertexts", %{key: key} do
    refute Cipher.seal_map(key, "favorite", %{"a" => 1}) ==
             Cipher.seal_map(key, "favorite", %{"a" => 1})
  end

  test "digests are stable per key and namespace, and differ across keys", %{
    key: key,
    other: other
  } do
    assert Cipher.digest(key, "catalog_item", 42) == Cipher.digest(key, "catalog_item", 42)
    refute Cipher.digest(key, "catalog_item", 42) == Cipher.digest(key, "series", 42)
    refute Cipher.digest(key, "catalog_item", 42) == Cipher.digest(other, "catalog_item", 42)
    assert byte_size(Cipher.digest(key, "catalog_item", 42)) == 32
  end

  # RFC 5869, test case 3 (zero-length salt and info), first 32 bytes.
  test "hkdf matches the RFC 5869 vector" do
    ikm = :binary.copy(<<0x0B>>, 22)

    assert Base.encode16(Cipher.hkdf(ikm, ""), case: :lower) ==
             "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d"
  end
end
