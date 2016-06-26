# -*- encoding: utf-8 -*-
#
# Copyright 2016 Matt Wrock <matt@mattwrock.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'nori'
require_relative 'powershell_output_decoder'
require_relative 'message_defragmenter'

module WinRM
  module PSRP
    # Class for reading powershell responses in Receive_Response messages
    class ReceiveResponseReader < WSMV::ReceiveResponseReader
      # Creates a new ReceiveResponseReader
      # @param transport [HttpTransport] The WinRM SOAP transport
      # @param logger [Logger] The logger to log diagnostic messages to
      def initialize(transport, logger)
        super
        @output_decoder = PowershellOutputDecoder.new
      end

      # Reads PSRP messages sent in one or more receive response messages
      # @param wsmv_message [WinRM::WSMV::Base] A wsmv message to send to endpoint
      # @param wait_for_done_state whether to poll for a CommandState of Done
      # @yield [Message] PSRP Message in response
      # @yieldreturn [Array<Message>] All messages in response
      def read_message(wsmv_message, wait_for_done_state = false)
        messages = []
        defragmenter = MessageDefragmenter.new
        read_response(wsmv_message, wait_for_done_state) do |stream|
          message = defragmenter.defragment(stream[:text])
          next unless message
          if block_given?
            yield message
          else
            messages.push(message)
          end
        end
        messages unless block_given?
      end

      # Reads streams and returns decoded output
      # @param wsmv_message [WinRM::WSMV::Base] A wsmv message to send to endpoint
      # @yieldparam [string] standard out response text
      # @yieldparam [string] standard error response text
      # @yieldreturn [WinRM::Output] The command output
      def read_output(wsmv_message)
        with_output do |output|
          read_message(wsmv_message, true) do |message|
            decoded_text = @output_decoder.decode(message)
            next unless decoded_text
            out = { stream_type(message) => decoded_text }
            output[:data] << out
            output[:exitcode] = find_exit_code(message)
            yield [out[:stdout], out[:stderr]] if block_given?
          end
        end
      end

      private

      def stream_type(message)
        type = :stdout
        case message.type
        when WinRM::PSRP::Message::MESSAGE_TYPES[:error_record]
          type = :stderr
        when WinRM::PSRP::Message::MESSAGE_TYPES[:pipeline_host_call]
          type = :stderr if message.data.include?('WriteError')
        end
        type
      end

      def find_exit_code(message)
        return nil unless message.type == WinRM::PSRP::Message::MESSAGE_TYPES[:pipeline_host_call]

        parser = Nori.new(
          parser: :rexml,
          advanced_typecasting: false,
          convert_tags_to: ->(tag) { tag.snakecase.to_sym },
          strip_namespaces: true
        )
        resp_objects = parser.parse(message.data)[:obj][:ms][:obj]

        resp_objects[1][:lst][:i32].to_i if resp_objects[0][:to_string] == 'SetShouldExit'
      end
    end
  end
end