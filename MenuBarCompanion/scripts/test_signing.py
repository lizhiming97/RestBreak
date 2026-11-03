import unittest
from signing import first_trusted_identity


class SigningTests(unittest.TestCase):
    def test_locally_valid_but_revoked_first_identity_is_skipped(self):
        chosen = first_trusted_identity(['OLD', 'NEW'], {'OLD': b'revoked', 'NEW': b'trusted'},
                                        lambda data: data == b'trusted')
        self.assertEqual(chosen, 'NEW')

    def test_explicit_revoked_identity_fails_without_switching(self):
        with self.assertRaises(RuntimeError):
            first_trusted_identity(['OLD', 'NEW'], {'OLD': b'revoked', 'NEW': b'trusted'},
                                   lambda data: data == b'trusted', requested='OLD')

    def test_all_revoked_does_not_silently_fall_back_to_adhoc(self):
        with self.assertRaises(RuntimeError):
            first_trusted_identity(['OLD'], {'OLD': b'revoked'}, lambda _: False)

    def test_unknown_public_certificate_is_not_signed(self):
        with self.assertRaises(RuntimeError):
            first_trusted_identity(['UNKNOWN'], {}, lambda _: True)

    def test_no_identities_or_explicit_local_adhoc(self):
        self.assertEqual(first_trusted_identity([], {}, lambda _: False), '-')
        self.assertEqual(first_trusted_identity(['OLD'], {}, lambda _: False, requested='-'), '-')


if __name__ == '__main__':
    unittest.main()
