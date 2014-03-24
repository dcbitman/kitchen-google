# -*- coding: utf-8 -*-

require_relative '../../spec_helper.rb'

require 'resolv'

describe Kitchen::Driver::Gce do

  let(:config) do
    { google_client_email: '123456789012@developer.gserviceaccount.com',
      google_key_location: '/home/user/gce/123456-privatekey.p12',
      google_project: 'alpha-bravo-123',
    }
  end

  let(:state) { Hash.new }

  let(:logged_output) { StringIO.new }
  let(:logger) { Logger.new(logged_output) }

  let(:instance) do
    double(
      logger: logger,
      name: 'default-distro-12'
    )
  end

  let(:driver) do
    d = Kitchen::Driver::Gce.new(config)
    d.instance = instance
    d.stub(:wait_for_sshd).and_return(true)
    d
  end

  let(:server) do
    fog = Fog::Compute::Google::Mock.new
    fog.servers.create(
      name: 'rspec-test-instance',
      machine_type: 'n1-standard-1',
      zone_name: 'us-central1-b'
    )
  end

  before(:each) do
    Fog.mock!
    Fog::Mock.reset
    Fog::Mock.delay = 0
  end

  describe '#initialize' do
    context 'with default options' do

      defaults = {
        area: 'us',
        inst_name: nil,
        machine_type: 'n1-standard-1',
        network: 'default',
        tags: [],
        username: ENV['USER'],
        zone_name: nil }

      defaults.each do |k, v|
        it "sets the correct default for #{k}" do
          expect(driver[k]).to eq(v)
        end
      end
    end

    context 'with overriden options' do
      overrides = {
        area: 'europe',
        inst_name: 'ci-instance',
        machine_type: 'n1-highmem-8',
        network: 'dev-net',
        tags: %w(qa integration),
        username: 'root',
        zone_name: 'europe-west1-a'
      }

      let(:config) { overrides }

      overrides.each do |k, v|
        it "overrides the default value for #{k}" do
          expect(driver[k]).to eq(v)
        end
      end
    end
  end

  describe '#connection' do
    context 'with required variables set' do
      it 'returns a Fog Compute object' do
        expect(driver.send(:connection)).to be_a(Fog::Compute::Google::Mock)
      end

      it 'uses the v1 api version' do
        conn = driver.send(:connection)
        expect(conn.api_version).to eq('v1')
      end
    end

    context 'without required variables set' do
      let(:config) { Hash.new }

      it 'raises an error' do
        expect { driver.send(:connection) }.to raise_error(ArgumentError)
      end
    end
  end

  describe '#create' do
    context 'with an existing server' do
      let(:state) do
        s = Hash.new
        s[:server_id] = 'default-distro-12345678'
        s
      end

      it 'returns if server_id already exists' do
        expect(driver.create(state)).to equal nil
      end
    end

    context 'when an instance is successfully created' do

      let(:driver) do
        d = Kitchen::Driver::Gce.new(config)
        d.stub(create_instance: server)
        d.stub(:wait_for_up_instance).and_return(nil)
        d
      end

      it 'sets a value for server_id in the state hash' do
        driver.send(:create, state)
        expect(state[:server_id]).to eq('rspec-test-instance')
      end

      it 'returns nil' do
        expect(driver.send(:create, state)).to equal(nil)
      end

    end

  end

  describe '#create_disk' do
    context 'with defaults and required options' do
      it 'returns a Google Disk object' do
        config[:image_name] = 'debian-7-wheezy-v20131120'
        config[:inst_name] = 'rspec-disk'
        config[:zone_name] = 'us-central1-a'
        expect(driver.send(:create_disk)).to be_a(Fog::Compute::Google::Disk)
      end
    end
  end

  describe '#create_instance' do
    context 'with default options' do
      it 'returns a Fog Compute Server object' do
        expect(driver.send(:create_instance)).to be_a(
          Fog::Compute::Google::Server)
      end
    end
  end

  describe '#destroy' do
    let(:state) do
      s = Hash.new
      s[:server_id] = 'rspec-test-instance'
      s[:hostname] = '198.51.100.17'
      s
    end

    it 'returns if server_id does not exist' do
      expect(driver.destroy({})).to equal nil
    end

    it 'removes the server state information' do
      driver.destroy(state)
      expect(state[:hostname]).to equal(nil)
      expect(state[:server_id]).to equal(nil)
    end
  end

  describe '#generate_inst_name' do
    context 'with a name less than 28 characters' do
      it 'concatenates the name and a UUID' do
        expect(driver.send(:generate_inst_name)).to match(
          /^default-distro-12-[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}$/)
      end
    end

    context 'with a name 28 characters or longer' do
      let(:instance) do
        double(name: '1234567890123456789012345678')
      end

      it 'shortens the base name and appends a UUID' do
        expect(driver.send(:generate_inst_name)).to match(
          /^123456789012345678901234567
            -[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}$/x)
      end
    end
  end

  describe '#select_zone' do
    context 'when choosing from any area' do
      let(:config) do
        { area: 'any',
          google_client_email: '123456789012@developer.gserviceaccount.com',
          google_key_location: '/home/user/gce/123456-privatekey.p12',
          google_project: 'alpha-bravo-123'
        }
      end

      it 'chooses from all zones' do
        expect(driver.send(:select_zone)).to satisfy do |zone|
          %w(europe-west1-a us-central1-a us-central1-b
             us-central2-a).include?(zone)
        end
      end
    end

    context 'when choosing from the "europe" area' do
      let(:config) do
        { area: 'europe',
          google_client_email: '123456789012@developer.gserviceaccount.com',
          google_key_location: '/home/user/gce/123456-privatekey.p12',
          google_project: 'alpha-bravo-123'
        }
      end

      it 'chooses a zone in europe' do
        expect(driver.send(:select_zone)).to satisfy do |zone|
          %w(europe-west1-a).include?(zone)
        end
      end
    end

    context 'when choosing from the default "us" area' do
      it 'chooses a zone in the us' do
        expect(driver.send(:select_zone)).to satisfy do |zone|
          %w(us-central1-a us-central1-b us-central2-a).include?(zone)
        end

      end
    end
  end

  describe '#wait_for_up_instance' do
    it 'sets the hostname' do
      driver.send(:wait_for_up_instance, server, state)
      # Mock instance gives us a random IP each time:
      expect(state[:hostname]).to match(Resolv::IPv4::Regex)
    end
  end
end
