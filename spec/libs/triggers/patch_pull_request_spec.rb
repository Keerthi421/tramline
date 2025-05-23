# frozen_string_literal: true

require "rails_helper"

describe Triggers::PatchPullRequest do
  let(:train) { create(:train) }
  let(:release) { create(:release, train:) }
  let(:commit) { create(:commit, release:) }
  let(:repo_integration) { instance_double(GithubIntegration) }
  let(:expected_title) { "[PATCH] [#{release.release_version}] #{commit.message}" }
  let(:expected_patch_branch) { "patch-#{train.working_branch}-#{commit.short_sha}" }
  let(:expected_description) {
    <<~TEXT
      - Cherry-pick #{commit.commit_hash} commit
      - Authored by: @#{commit.author_login}

      #{commit.message}
    TEXT
  }
  let(:pr_source_id) { Faker::Lorem.word }
  let(:pr_number) { Faker::Number.number(digits: 2) }
  let(:created_pr) {
    {
      source_id: pr_source_id,
      number: pr_number,
      title: expected_title,
      body: expected_description,
      url: Faker::Internet.url,
      state: "open",
      head_ref: expected_patch_branch,
      base_ref: train.working_branch,
      opened_at: Time.current,
      source: :github
    }
  }
  let(:merged_pr) {
    {
      source_id: pr_source_id,
      number: pr_number,
      title: expected_title,
      body: expected_description,
      url: Faker::Internet.url,
      state: "closed",
      head_ref: expected_patch_branch,
      base_ref: train.working_branch,
      opened_at: Time.current,
      source: :github
    }
  }

  before do
    allow(train).to receive(:vcs_provider).and_return(repo_integration)
    allow(repo_integration).to receive_messages(
      create_patch_pr!: created_pr,
      get_pr: created_pr,
      pr_closed?: false,
      enable_auto_merge!: true,
      enable_auto_merge?: true,
      merge_pr!: merged_pr
    )
  end

  it "creates a patch PR" do
    described_class.call(release, commit)

    expect(repo_integration).to have_received(:create_patch_pr!).with(
      train.working_branch,
      expected_patch_branch,
      commit.commit_hash,
      expected_title,
      expected_description
    )
    expect(commit.reload.pull_request).to be_present
  end

  it "updates the existing PR if it already exists" do
    existing_pr = create(:pull_request, release:, commit:, phase: :mid_release)

    described_class.call(release, commit)

    expect(repo_integration).not_to have_received(:create_patch_pr!).with(
      train.working_branch,
      expected_patch_branch,
      commit.commit_hash,
      expected_title,
      expected_description
    )
    expect(commit.reload.pull_request).to eq(existing_pr)
  end

  it "finds the PR if it already exists" do
    allow(repo_integration).to receive(:create_patch_pr!).and_raise(Installations::Error.new("duplicate", reason: :pull_request_already_exists))
    allow(repo_integration).to receive(:find_pr).and_return(created_pr)

    described_class.call(release, commit)
    expect(repo_integration).to have_received(:find_pr)
  end

  it "creates an mid release back merge PR for the release" do
    described_class.call(release, commit)

    expect(release.pull_requests.mid_release.back_merge_type.size).to eq(1)
    persisted_pr = release.pull_requests.mid_release.back_merge_type.sole
    expect(persisted_pr.title).to eq(expected_title)
    expect(persisted_pr.body).to eq(expected_description)
    expect(persisted_pr.head_ref).to eq(expected_patch_branch)
  end

  it "enables auto merge for the created patch PR" do
    allow(repo_integration).to receive(:merge_pr!).and_raise(Installations::Error.new("MergeError", reason: :pull_request_not_mergeable))
    described_class.call(release, commit)

    expect(repo_integration).to have_received(:enable_auto_merge!)
  end
end
