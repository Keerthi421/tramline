module Installations
  class Google::PlayDeveloper::Api
    ANDROID_PUBLISHER = ::Google::Apis::AndroidpublisherV3
    SERVICE = ANDROID_PUBLISHER::AndroidPublisherService
    SERVICE_ACCOUNT = ::Google::Auth::ServiceAccountCredentials
    SCOPE = ANDROID_PUBLISHER::AUTH_ANDROIDPUBLISHER
    CONTENT_TYPE = "application/octet-stream".freeze

    RELEASE_STATUS = {
      in_progress: "inProgress",
      halted: "halted",
      draft: "draft",
      completed: "completed"
    }.freeze

    attr_reader :package_name, :key_file, :client

    def initialize(package_name, key_file)
      @package_name = package_name
      @key_file = key_file

      set_api_defaults
      set_client
    end

    def app_details(transforms)
      execute do
        edit = client.insert_edit(package_name)
        client.get_edit_detail(package_name, edit.id)
          &.to_h
          &.then { |details| Installations::Response::Keys.transform([details], transforms) }
          &.first
      end
    end

    def upload(apk_path, skip_review: nil)
      execute do
        edit = client.insert_edit(package_name)
        client.upload_edit_bundle(package_name, edit.id, upload_source: apk_path, content_type: CONTENT_TYPE)
        client.commit_edit(package_name, edit.id, changes_not_sent_for_review: skip_review)
      end
    end

    def find_latest_build_number(apk: false)
      execute do
        edit = client.insert_edit(package_name)

        if apk
          return client.list_edit_apks(package_name, edit.id)
              &.apks
              &.max_by(&:version_code)
              &.version_code
        end

        client.list_edit_bundles(package_name, edit.id)
          &.bundles
          &.max_by(&:version_code)
          &.version_code
      end
    end

    def find_build(build_number, apk: false)
      execute do
        edit = client.insert_edit(package_name)

        if apk
          return client.list_edit_apks(package_name, edit.id)
              &.apks
              &.find { |b| b.version_code.to_s == build_number.to_s }
              &.to_h
        end

        client.list_edit_bundles(package_name, edit.id)
          &.bundles
          &.find { |b| b.version_code.to_s == build_number.to_s }
          &.to_h
      end
    end

    def list_tracks(transforms)
      execute do
        edit = client.insert_edit(package_name)
        client.list_edit_tracks(package_name, edit.id)
          &.tracks
          &.map { |t| t.to_h }
          &.then { |tracks| Installations::Response::Keys.transform(tracks, transforms) }
      end
    end

    def get_track(track_name, transforms)
      execute do
        edit = client.insert_edit(package_name)
        client.get_edit_track(package_name, edit.id, track_name)
          &.to_h
          &.then { |track| Installations::Response::Keys.transform([track], transforms) }
          &.first
      end
    end

    def create_release(track_name, version_code, release_version, rollout_percentage, release_notes, skip_review: nil)
      @track_name = track_name
      @version_code = version_code
      @release_version = release_version
      @rollout_percentage = rollout_percentage
      @release_notes = truncated_release_notes(release_notes)

      execute do
        edit = client.insert_edit(package_name)
        edit_track(edit, active_release)
        client.commit_edit(package_name, edit.id, changes_not_sent_for_review: skip_review)
      end
    end

    def create_draft_release(track_name, version_code, release_version, release_notes, skip_review: nil)
      @track_name = track_name
      @version_code = version_code
      @release_version = release_version
      @release_notes = truncated_release_notes(release_notes)

      execute do
        edit = client.insert_edit(package_name)
        edit_track(edit, draft_release)
        client.commit_edit(package_name, edit.id, changes_not_sent_for_review: skip_review)
      end
    end

    def halt_release(track_name, version_code, release_version, rollout_percentage, skip_review: nil)
      @track_name = track_name
      @version_code = version_code
      @release_version = release_version
      @rollout_percentage = rollout_percentage

      execute do
        edit = client.insert_edit(package_name)
        edit_track(edit, halted_release)
        client.commit_edit(package_name, edit.id, changes_not_sent_for_review: skip_review)
      end
    end

    private

    NOTES_MAX_LENGTH = 500

    attr_writer :track_name, :version_code, :release_version, :rollout_percentage

    def truncated_release_notes(release_notes)
      return [] if release_notes.blank?
      release_notes.map do |rn|
        rn[:text] = rn[:text].truncate(NOTES_MAX_LENGTH)
        rn
      end
    end

    def edit_track(edit, release)
      client.update_edit_track(package_name, edit.id, @track_name, track(release))
    end

    def track(release)
      ANDROID_PUBLISHER::Track.new(track: @track_name, releases: [release])
    end

    def active_release
      rollout_status = @rollout_percentage.eql?(100) ? RELEASE_STATUS[:completed] : RELEASE_STATUS[:in_progress]
      params = release_params.merge(status: rollout_status)
      params[:release_notes] = @release_notes if @release_notes.present?
      params[:user_fraction] = user_fraction if @rollout_percentage && user_fraction < 1.0
      ANDROID_PUBLISHER::TrackRelease.new(**params)
    end

    def draft_release
      params = release_params.merge(status: RELEASE_STATUS[:draft], release_notes: @release_notes)
      ANDROID_PUBLISHER::TrackRelease.new(**params)
    end

    def halted_release
      params = release_params.merge(status: RELEASE_STATUS[:halted], user_fraction: user_fraction)
      ANDROID_PUBLISHER::TrackRelease.new(**params)
    end

    def user_fraction
      @rollout_percentage.to_f / 100.0
    end

    def release_params
      {name: @release_version, version_codes: [@version_code]}
    end

    def execute
      yield if block_given?
    rescue ::Google::Apis::ServerError, ::Google::Apis::ClientError, ::Google::Apis::AuthorizationError => e
      raise Installations::Google::PlayDeveloper::Error.new(e)
    end

    def set_client
      auth_client = SERVICE_ACCOUNT.make_creds(json_key_io: key_file, scope: SCOPE)
      service = SERVICE.new
      service.authorization = auth_client
      @client ||= service
    end

    def set_api_defaults
      ::Google::Apis::ClientOptions.default.read_timeout_sec = 300
      ::Google::Apis::ClientOptions.default.open_timeout_sec = 300
      ::Google::Apis::ClientOptions.default.send_timeout_sec = 300
      ::Google::Apis::RequestOptions.default.retries = 5
    end
  end
end
