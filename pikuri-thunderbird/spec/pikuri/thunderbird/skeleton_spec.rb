# frozen_string_literal: true

# Skeleton smoke test: the gem requires cleanly, defines its namespace,
# mounts its own loader, and pulls pikuri-core. Per-component specs land
# alongside each piece (Profile, DatabaseSnapshot, Gloda, Calendar, the tools).
describe 'pikuri-thunderbird skeleton' do
  it 'defines the Pikuri::Thunderbird namespace' do
    assert defined?(Pikuri::Thunderbird), 'Pikuri::Thunderbird should be defined after require'
    assert_kind_of Module, Pikuri::Thunderbird
  end

  it 'mounts its own Zeitwerk loader tagged pikuri-thunderbird' do
    assert_equal 'pikuri-thunderbird', Pikuri::Thunderbird::LOADER.tag
  end

  it 'loads pikuri-core into the shared namespace' do
    assert defined?(Pikuri::Agent), 'pikuri-core should be required'
    assert defined?(Pikuri::Tool), 'pikuri-core Tool base class should be available'
  end
end
