package DDGC::DB::Result::User;
# ABSTRACT: Result class of a user in the DB

use Moose;
use MooseX::NonMoose;
extends 'DDGC::DB::Base::Result';
use DBIx::Class::Candy;
use DDGC::User::Page;
use Path::Class;
use IPC::Run qw/ run timeout /;
use LWP::Simple qw/ is_success getstore /;
use File::Temp qw/ tempfile /;
use Carp;
use Prosody::Mod::Data::Access;
use Digest::MD5 qw( md5_hex );
use List::MoreUtils qw( uniq  );
use namespace::autoclean;

table 'users';

sub u_userpage {
	my ( $self ) = @_;
	return ['Root','default'] unless $self->public_username;
	return ['Userpage','home',$self->public_username];
}

column id => {
	data_type => 'bigint',
	is_auto_increment => 1,
};
primary_key 'id';

unique_column username => {
	data_type => 'text',
	is_nullable => 0,
};
sub lowercase_username { lc(shift->username) }
sub lc_username { lc(shift->username) }

column public => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 0,
};

column privacy => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 1,
};

column email_notification_content => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 1,
};

column admin => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 0,
};

column ghosted => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 1,
};

column ignore => {
	data_type => 'int',
	is_nullable => 0,
	default_value => 0,
};

column email => {
	data_type => 'text',
	is_nullable => 1,
};

column gravatar_email => {
	data_type => 'text',
	is_nullable => 1,
};

column userpage => {
	data_type => 'text',
	is_nullable => 1,
	serializer_class => 'JSON',
};

column data => {
	data_type => 'text',
	is_nullable => 1,
	serializer_class => 'YAML',
};

column notes => {
	data_type => 'text',
	is_nullable => 1,
};

column profile_media_id => {
	data_type => 'bigint',
	is_nullable => 1,
};

column created => {
	data_type => 'timestamp with time zone',
	set_on_create => 1,
};

column updated => {
	data_type => 'timestamp with time zone',
	set_on_create => 1,
	set_on_update => 1,
};

column roles => {
	data_type => 'text',
	is_nullable => 1,
	default_value => '',
};

column flags => {
	data_type => 'text',
	is_nullable => 0,
	serializer_class => 'JSON',
	default_value => '[]',
};

has xmpp => (
	isa => 'HashRef',
	is => 'ro',
	lazy_build => 1,
);

sub _build_xmpp {
	my ( $self ) = @_;
	return { $self->ddgc->xmpp->user($self->username) };
}

sub userpage_obj {
	my ( $self ) = @_;
	return DDGC::User::Page->new_from_user($self);
}

around data => sub {
	my ( $orig, $self, @args ) = @_;
	my $data = $orig->($self,@args);
	$data = {} unless $data;
	return $data;
};

has_many 'token_language_translations', 'DDGC::DB::Result::Token::Language::Translation', { 'foreign.username' => 'self.username' }, {
  cascade_delete => 0,
};
has_many 'token_languages', 'DDGC::DB::Result::Token::Language', 'translator_users_id', {
  cascade_delete => 0,
};
has_many 'checked_translations', 'DDGC::DB::Result::Token::Language::Translation', 'check_users_id', {
  cascade_delete => 0,
};
has_many 'translation_votes', 'DDGC::DB::Result::Token::Language::Translation::Vote', 'users_id', {
  cascade_delete => 1,
};
has_many 'comments', 'DDGC::DB::Result::Comment', 'users_id', {
  cascade_delete => 0,
};
has_many 'duckpan_releases', 'DDGC::DB::Result::DuckPAN::Release', 'users_id', {
  cascade_delete => 0,
};
has_many 'threads', 'DDGC::DB::Result::Thread', 'users_id', {
  cascade_delete => 0,
};
has_many 'ideas', 'DDGC::DB::Result::Idea', 'users_id', {
  cascade_delete => 0,
};
has_many 'events', 'DDGC::DB::Result::Event', 'users_id', {
  cascade_delete => 0,
};
has_many 'medias', 'DDGC::DB::Result::Media', 'users_id', {
  cascade_delete => 0,
};

has_many 'user_languages', 'DDGC::DB::Result::User::Language', { 'foreign.username' => 'self.username' }, {
  cascade_delete => 1,
};
has_many 'user_notifications', 'DDGC::DB::Result::User::Notification', 'users_id', {
  cascade_delete => 1,
};
has_many 'user_notification_matrixes', 'DDGC::DB::Result::User::Notification::Matrix', 'users_id', {
  cascade_delete => 0,
};
has_many 'user_blogs', 'DDGC::DB::Result::User::Blog', 'users_id', {
  cascade_delete => 1,
};
has_many 'user_reports', 'DDGC::DB::Result::User::Report', 'users_id', {
  cascade_delete => 0,
};
has_many 'github_users', 'DDGC::DB::Result::GitHub::User', 'users_id', {
  cascade_delete => 0,
};

many_to_many 'languages', 'user_languages', 'language';

belongs_to 'profile_media', 'DDGC::DB::Result::Media', 'profile_media_id', { join_type => 'left' };

after insert => sub {
	my ( $self ) = @_;
	$self->add_default_notifications;
};

sub add_default_notifications {
	my ( $self ) = @_;
	return if $self->search_related('user_notifications')->count;
	$self->add_type_notification(qw( replies 2 1 ));
	$self->add_type_notification(qw( forum_comments 2 1 ));
	$self->add_type_notification(qw( blog_comments 2 1 ));
	$self->add_type_notification(qw( translation_votes 3 1 ));
	$self->add_type_notification(qw( idea_votes 3 1 ));
}

# WORKAROUND
sub db { return shift; }

sub translation_manager { shift->is('translation_manager') }

sub github_user {
	my ( $self ) = @_;
	return $self->search_related('github_users',{},{
		order_by => { -desc => 'updated' }
	})->first;
}

sub is {
	my ( $self, $flag ) = @_;
	return 1 if $self->admin;
	return $self->has_flag($flag);
}

sub has_flag {
	my ( $self, $flag ) = @_;
	return 0 unless $flag;
	return 1 if grep { $_ eq $flag } @{$self->flags};
	return 0;
}

sub add_flag {
	my ( $self, $flag ) = @_;
	return 0 if grep { $_ eq $flag } @{$self->flags};
	push @{$self->flags}, $flag;
	$self->make_column_dirty("flags");
	return 1;
}

sub del_flag {
	my ( $self, $flag ) = @_;
	return 0 unless grep { $_ eq $flag } @{$self->flags};
	my @newflags = grep { $_ ne $flag } @{$self->flags};
	$self->flags(\@newflags);
	$self->make_column_dirty("flags");
	return 1;
}

has _locale_user_languages => (
	isa => 'HashRef[DDGC::DB::Result::User::Language]',
	is => 'ro',
	lazy_build => 1,
);
sub lul { shift->_locale_user_languages }
sub locales { shift->_locale_user_languages }

sub can_speak {
	my ( $self, $locale ) = @_;
	return defined $self->lul->{$locale};
}

sub _build__locale_user_languages {
	my ( $self ) = @_;
	my @user_languages = $self->user_languages;
	my %lul;
	for (@user_languages) {
		$lul{$_->language->locale} = $_;
	}
	return \%lul;
}

sub translation_count { shift->token_language_translations->count(@_); }

sub undone_notifications_count_resultset {
	my ( $self ) = @_;
	$self->schema->resultset('Event::Notification::Group')->search_rs({
		'user_notification.users_id' => $self->id,
	},{
		prefetch => [qw( user_notification_group ),{
			event_notifications => [qw( user_notification )],
		}],
		cache_for => 45,
	})
}

sub undone_notifications_count {
	my ( $self ) = @_;
	$self->undone_notifications_count_resultset->count;
}

sub undone_notifications {
	my ( $self, $limit ) = @_;
	$self->schema->resultset('Event::Notification::Group')->prefetch_all->search_rs({
		'user_notification.users_id' => $self->id,
	},{
		order_by => { -desc => 'event_notifications.created' },
		cache_for => 45,
		$limit ? ( rows => $limit ) : (),
	});
}

sub unsent_notifications_cycle {
	my ( $self, $cycle ) = @_;
	$self->schema->resultset('Event::Notification::Group')->prefetch_all->search_rs({
		'event_notifications.sent' => 0,
		'user_notification.cycle' => $cycle,
		'user_notification.users_id' => $self->id,
	},{
		order_by => { -desc => 'event_notifications.created' },
	});	
}

sub has_access_to_notification {
	my ( $self, $context_obj ) = @_;
	return 1 if (!$context_obj->isa('DDGC::DB::Result::Thread') && !$context_obj->isa('DDGC::DB::Result::Comment'));
	return $context_obj->user_has_access($self);
}

sub is_subscribed_and_notification_is_special {
	my ( $self, $context_obj ) = @_;
	return 1 if $self->admin;
	my $t;
	$t = $context_obj if $context_obj->isa('DDGC::DB::Result::Thread');
	$t = $context_obj->thread if $context_obj->isa('DDGC::DB::Result::Comment');
	if ( $t && $t->forum_is('special') ) {
		return $self->user_notifications->find( {
				'me.context_id' => $t->id,
				'user_notification_group.context' => 'DDGC::DB::Result::Thread',
			}, { join => 'user_notification_group' } );
	}
	return 1;
}

sub blog { shift->user_blogs_rs }

# This validation is performed on signup, but better to do it again, prevent traversal etc.
sub username_to_filename {
	my ($self) = @_;
	my $n = $self->username;
	$n =~ s/[^A-Za-z0-9_-]+/_/g;
	return $n;
}

sub user_avatar_directory {
	my ($self) = @_;
	my @d = (split '',$self->username_to_filename)[0..1];
	push @d, $self->username;
	return @d;
}

sub avatar_stash_directory {
	my ($self, $opts) = @_;
	my $dir = dir($self->avatar_directory, 'stash');
	$dir->mkpath if ($opts->{mkpath});
	return $dir->stringify;
}

sub avatar_url {
	my ($self) = @_;
	my $fn = $self->username_to_filename;
	return file('/media/avatar/', $self->user_avatar_directory, $fn)->stringify;
}

sub stash_url {
	my ($self) = @_;
	return dir('/media/avatar/', $self->user_avatar_directory, 'stash')->stringify;
}

sub avatar_directory {
	my ($self, $opts) = @_;
	my $dir = dir($self->ddgc->config->mediadir, 'avatar', $self->user_avatar_directory);
	$dir->mkpath if ($opts->{mkpath});
	return $dir->stringify;
}

sub avatar_filename {
	my ($self, $opts) = @_;
	my $fn = $self->username_to_filename;
	return file($self->avatar_directory($opts), $fn)->stringify;
}

sub profile_picture {
	my ( $self, $size ) = @_;

	return unless $self->public;

	my %return;
	for (qw/16 32 48 64 80/) {
		my $fn = $self->avatar_filename . "_$_";
		return undef unless ( -f $fn );
		$return{$_} = $self->avatar_url . "_$_";
	}

	if ($size) {
		return $return{$size};
	} else {
		return \%return;
	}
}

sub gravatar_to_avatar {
	my ($self) = @_;
	return unless $self->public;
	my $gravatar_email;
	return if (-f $self->avatar_filename );

	if ($self->data && defined $self->data->{gravatar_email}) {
		$gravatar_email = $self->data->{gravatar_email};
	}

	if ($self->data && defined $self->data->{userpage} && defined $self->data->{userpage}->{gravatar_email}) {
		$gravatar_email = $self->data->{userpage}->{gravatar_email};
	}

	if ($self->userpage && defined $self->userpage->{gravatar_email}) {
		$gravatar_email = $self->userpage->{gravatar_email};
	}

	return unless $gravatar_email;
	my $md5 = md5_hex($gravatar_email);

	my ($fh, $filename) = tempfile();
	my $url = "http://www.gravatar.com/avatar/$md5?r=g&s=200";

	unless (is_success(getstore($url, $filename))) {
		carp("Unable to retrieve $url for " . $self->username);
		return 0;
	}

	return unless $self->store_avatar($filename);
	$self->generate_thumbs;
}

sub generate_thumbs {
	my ($self) = @_;
	my $fn = $self->username_to_filename;
	my $avatar = $self->avatar_filename;
	my ( $in, $out, $err );
	for my $size ( qw/16 32 48 64 80/ ) {
		run [ convert => ( "$avatar",
			'-resize', "${size}x${size}"."^",
			'-gravity', 'center', '-strip',
			'-crop', "${size}x${size}"."+0+0",
			'+repage', "${avatar}_$size",
		)], \$in, \$out, \$err, timeout(60) or die "$err (error $?) $out";
	}
}

sub store_avatar {
	my ($self, $file) = @_;
	my $destination = ($self->avatar_filename({ mkpath => 1 }));
	return 0 unless ( -f $file );
	$self->ddgc->copy_image($file, "$destination") or croak "Error storing avatar";
}

sub files_in_stash {
	my ($self) = @_;
	my $dh;
	my $dir = $self->avatar_stash_directory;
	if (-d $dir) {
		opendir $dh, $dir;
		return sort { -M $b <=> -M $a } grep { -f $_ } map { file($dir, $_)->stringify } readdir $dh;
	}
	return undef;
}

sub reload_stash {
	my ($self) = @_;
	my @stash;
	my @files = $self->files_in_stash;
	return unless @files;
	for my $file (@files) {
		(my $basename = $file) =~ s/.*\/(.*)/$1/;
		next unless $basename;
		(my $name = $basename) =~ s/\./_/g;
		push @stash, { name => $name, avatar_id => $basename, media_url => file($self->stash_url, $basename)->stringify }
	}
	return @stash or undef;
}

sub set_avatar {
	my ($self) = @_;
	$self->delete_avatar if (-f $self->avatar_filename . "_delete" );
	my @files = $self->files_in_stash;
	return unless @files;
	return unless $self->store_avatar($files[-1]);
	$self->generate_thumbs;
	unlink @files;
}

sub queue_delete_avatar {
	my ($self, $filename) = @_;
	return unless $filename;
	if ($filename eq 'current') {
		open my $fh, '>', $self->avatar_filename . '_delete';
	}
	else {
		my $file = file($self->avatar_stash_directory, $filename)->stringify;
		unlink $file if (-f $file);
	}
}

sub delete_avatar {
	my ($self) = @_;
	my $avatar = $self->avatar_filename;
	unlink("$avatar") if (-f "$avatar");
	for my $size ( qw/delete 16 32 48 64 80/ ) {
		unlink ("${avatar}_$size") if (-f "${avatar}_$size");
	}
}

sub stash_avatar {
	my ($self, $avatar) = @_;
	my $destination = file($self->avatar_stash_directory({mkpath => 1}), $avatar->filename)->stringify;
	return { success => 0, msg => 'A file with this name has already been uploaded' } if (-f "$destination");
	$self->ddgc->copy_image($avatar->tempname, "$destination") or return { success => 0, msg => 'Error uploading image. Perhaps your file is corrupt.' };
	return { success => 1 };
}

sub public_username {
	my ( $self ) = @_;
	if ($self->public) {
		return $self->username;
	}
	return;
}

sub add_report {
	my ( $self, $context, $context_id, %data ) = @_;
	return $self->create_related('user_reports',{
		context => $context,
		context_id => $context_id,
		%data,
	});
}

sub last_comments {
	my ( $self, $page, $pagesize ) = @_;
	$self->comments->search({},{
		order_by => { -desc => [ 'me.updated', 'me.created' ] },
		( ( defined $page and defined $pagesize ) ? (
			page => $page,
			rows => $pagesize,
		) : () ),
		prefetch => 'user',
	});
}

has user_notification_group_values => (
	isa => 'HashRef',
	is => 'ro',
	lazy_build => 1,
	clearer => 'clear_user_notification_group_values',
);

sub _build_user_notification_group_values {
	my ( $self ) = @_;
	my %user_notification_group_values;
	for ($self->search_related('user_notifications',{
		context_id => undef,
	},{
		join => [qw( user_notification_group )],
	})->all) {
		$user_notification_group_values{$_->user_notification_group->type} = {}
			unless defined $user_notification_group_values{$_->user_notification_group->type};
		my $context_id_key = $_->user_notification_group->with_context_id
			? '*' : '';
		$user_notification_group_values{$_->user_notification_group->type}->{$context_id_key}
			= { cycle => $_->cycle, xmpp => $_->xmpp };
	}
	return \%user_notification_group_values;
}

sub add_context_notification {
	my ( $self, $type, $context_obj ) = @_;
	my $group_info = $self->user_notification_group_values->{$type}->{'*'};
	if ($group_info->{cycle} ||
		($type eq 'forum_comments' && $context_obj->isa('DDGC::DB::Result::Thread') && $context_obj->forum_is('special'))) {
		my @user_notification_groups = $self->schema->resultset('User::Notification::Group')->search({
			context => $context_obj->context_name,
			with_context_id => 1,
			type => $type,
		})->all;
		die "Several notification groups found, cant be..." if scalar @user_notification_groups > 1;
		die "No notification group found!" if scalar @user_notification_groups < 1;
		my $user_notification_group = $user_notification_groups[0];
		return $self->update_or_create_related('user_notifications',{
			user_notification_group_id => $user_notification_group->id,
			xmpp => $group_info->{xmpp} ? 1 : 0,
			cycle => $group_info->{cycle} // 3,
			context_id => $context_obj->id,
		},{
			key => 'user_notification_user_notification_group_id_context_id_users_id',
		});
	}
}

sub has_context_notification {
	my ( $self, $type, $context_obj ) = @_;
	my $group_info = $self->user_notification_group_values->{$type}->{'*'};
	my @user_notification_groups = $self->schema->resultset('User::Notification::Group')->search({
		context => $context_obj->context_name,
		with_context_id => 1,
		type => $type,
	})->all;
	die "Several notification groups found, cant be..." if scalar @user_notification_groups > 1;
	die "No notification group found!" if scalar @user_notification_groups < 1;
	my $user_notification_group = $user_notification_groups[0];
	return $self->search_related('user_notifications',{
		user_notification_group_id => $user_notification_group->id,
		context_id => $context_obj->id,
	})->count;
}

sub delete_context_notification {
	my ( $self, $type, $context_obj ) = @_;
	my $group_info = $self->user_notification_group_values->{$type}->{'*'};
	my @user_notification_groups = $self->schema->resultset('User::Notification::Group')->search({
		context => $context_obj->context_name,
		with_context_id => 1,
		type => $type,
	})->all;
	die "Several notification groups found, cant be..." if scalar @user_notification_groups > 1;
	die "No notification group found!" if scalar @user_notification_groups < 1;
	my $user_notification_group = $user_notification_groups[0];
	return $self->search_related('user_notifications',{
		user_notification_group_id => $user_notification_group->id,
		context_id => $context_obj->id,
	})->delete;
}

sub add_type_notification {
	my ( $self, $type, $cycle, $with_context_id ) = @_;
	my @user_notification_groups = $self->schema->resultset('User::Notification::Group')->search({
		with_context_id => $with_context_id ? 1 : 0,
		type => $type,
	})->all;
	die "No notification group found!" if scalar @user_notification_groups < 1;
	for my $user_notification_group (@user_notification_groups) {
		if ($cycle) {
			$self->update_or_create_related('user_notifications',{
				user_notification_group_id => $user_notification_group->id,
				context_id => undef,
				cycle => $cycle,
			},{
				key => 'user_notification_user_notification_group_id_context_id_users_id',
			});
			if ($with_context_id) {
				$self->search_related('user_notifications',{
					user_notification_group_id => $user_notification_group->id,
					context_id => { '!=' => undef },
				})->update({
					cycle => $cycle,
				});
			}
		} else {
			$self->search_related('user_notifications',{
				user_notification_group_id => $user_notification_group->id,
				context_id => undef,
			})->delete;
			if ($with_context_id) {
				$self->search_related('user_notifications',{
					user_notification_group_id => $user_notification_group->id,
					context_id => { '!=' => undef },
				})->delete;
			}
		}
	}
}

sub seen_campaign_notice {
	my ( $self, $thread_id ) = @_;
	return ( $self->schema->resultset('User::CampaignNotice')->find({ users_id => $self->id, thread_id => $thread_id }) )? 1 : 0;
}

sub check_password {
	my ( $self, $password ) = @_;
	return 1 unless $self->ddgc->config->prosody_running;
	my $mod_data_access = Prosody::Mod::Data::Access->new(
		jid => lc($self->username).'@'.$self->ddgc->config->prosody_userhost,
		password => $password,
	);
	my $data;
	eval {
		$data = $mod_data_access->get(lc($self->username));
	};
	return $data ? 1 : 0;
}

# For Catalyst

# Store given by Catalyst
has store => (
	is => 'rw',
);

# Auth Realm given by Catalyst
has auth_realm => (
	is => 'rw',
);

sub supports {{}}

sub for_session {
	return shift->username;
}

sub get_object {
	return shift;
}
 
sub obj {
	my $self = shift;
	return $self->get_object(@_);
}

sub get {
	my ($self, $field) = @_;

	my $object;
	if ($object = $self->get_object and $object->can($field)) {
		return $object->$field();
	} else {
		return undef;
	}
}
### END

no Moose;
__PACKAGE__->meta->make_immutable;
