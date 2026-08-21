from mailu import models


def _make_user(email='user@example.com', **kwargs):
    """ Create a user (and its domain) with the given attributes. """
    domain_name = email.split('@', 1)[1]
    if not models.Domain.query.filter_by(name=domain_name).first():
        models.db.session.add(models.Domain(name=domain_name))
        models.db.session.commit()
    user = models.User(localpart=email.split('@', 1)[0], domain_name=domain_name,
                       **kwargs)
    user.set_password('password')
    models.db.session.add(user)
    models.db.session.commit()
    return user


class TestDovecotInternalEndpoints:
    """ Contract tests for the endpoints the imap container consumes.

    Dovecot reaches these over HTTP from ``core/dovecot/conf/login.lua``
    (passdb, userdb) and through podop (quota, sieve). The names and the shape
    of the returned fields are a wire contract with software outside this
    repository: dropping or renaming one of them breaks authentication or quota
    accounting silently, because the docker-compose tests only exercise IMAP
    delivery and never look at these replies.
    """

    def test_passdb_grants_nopassword_within_the_trusted_subnet(self, app, client):
        """ Dovecot does not verify passwords itself in Mailu.

        The front has already authenticated the user against
        ``/internal/auth/email``, so passdb answers ``nopassword`` and limits
        that trust to ``allow_real_nets``. Losing either field turns the mailbox
        into an open relay for anyone who can reach port 143, so both are
        pinned here.
        """
        with app.app_context():
            user = _make_user()
            rv = client.get(f'/internal/dovecot/passdb/{user.email}')
            assert rv.status_code == 200
            reply = rv.get_json()
            assert reply['nopassword'] == 'Y'
            assert reply['password'] is None
            assert reply['allow_real_nets'] == app.config['SUBNET']

    def test_passdb_allow_real_nets_covers_both_address_families(self, app, client):
        """ With SUBNET6 configured, IPv6 clients of the front must be trusted
            as well, as a second comma separated entry. """
        with app.app_context():
            user = _make_user()
            app.config['SUBNET6'] = 'fd80::/64'
            rv = client.get(f'/internal/dovecot/passdb/{user.email}')
            assert rv.status_code == 200
            nets = rv.get_json()['allow_real_nets'].split(',')
            assert nets == [app.config['SUBNET'], 'fd80::/64']

    def test_userdb_reports_the_quota_as_a_dovecot_quota_rule(self, app, client):
        """ The user's quota reaches dovecot as a userdb field, in dovecot's
            own ``quota_rule`` syntax rather than as a plain number. """
        with app.app_context():
            user = _make_user(quota_bytes=1234567)
            rv = client.get(f'/internal/dovecot/userdb/{user.email}')
            assert rv.status_code == 200
            assert rv.get_json() == {'quota_rule': '*:bytes=1234567'}

    def test_userdb_iteration_lists_enabled_users_only(self, app, client):
        """ The iteration endpoint backs ``doveadm user '*'`` and therefore every
            ``doveadm -A`` command. Disabled users must stay out of it so that
            bulk operations do not touch deactivated mailboxes. """
        with app.app_context():
            active = _make_user('active@example.com')
            disabled = _make_user('disabled@example.com', enabled=False)
            rv = client.get('/internal/dovecot/userdb/')
            assert rv.status_code == 200
            listed = rv.get_json()
            assert active.email in listed
            assert disabled.email not in listed

    def test_quota_storage_post_records_the_reported_usage(self, app, client):
        """ Dovecot pushes the mailbox size back through the quota dict, which
            is what the admin UI and the API report as used space. """
        with app.app_context():
            user = _make_user()
            rv = client.post(f'/internal/dovecot/quota/storage/{user.email}',
                             json=54321)
            assert rv.status_code == 200
            assert models.User.query.get(user.email).quota_bytes_used == 54321

    def test_quota_post_ignores_namespaces_other_than_storage(self, app, client):
        """ Dovecot also clones the message count. Only the storage namespace
            carries a byte count, so anything else must be accepted and
            discarded rather than overwriting the recorded size. """
        with app.app_context():
            user = _make_user()
            client.post(f'/internal/dovecot/quota/storage/{user.email}', json=54321)
            rv = client.post(f'/internal/dovecot/quota/messages/{user.email}',
                             json=7)
            assert rv.status_code == 200
            assert models.User.query.get(user.email).quota_bytes_used == 54321

    def test_sieve_default_script_follows_the_users_spam_settings(self, app, client):
        """ The default script is generated per user and pulled in through
            ``sieve_before``. It has to reflect that user's spam settings,
            otherwise spam filtering silently stops matching. """
        with app.app_context():
            filtering = _make_user('filtering@example.com', spam_enabled=True,
                                   spam_threshold=42)
            rv = client.get(f'/internal/dovecot/sieve/data/default/{filtering.email}')
            assert rv.status_code == 200
            script = rv.get_json()
            assert 'spamtest :percent' in script
            assert '"42"' in script

            unfiltered = _make_user('unfiltered@example.com', spam_enabled=False)
            rv = client.get(f'/internal/dovecot/sieve/data/default/{unfiltered.email}')
            assert rv.status_code == 200
            # note: require "spamtestplus" is unconditional, only the test is
            # dropped, so match the conditional block rather than the substring
            assert 'spamtest :percent' not in rv.get_json()
