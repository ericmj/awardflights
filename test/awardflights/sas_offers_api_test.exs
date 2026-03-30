defmodule Awardflights.SasOffersApiTest do
  use ExUnit.Case, async: true

  alias Awardflights.SasOffersApi

  setup do
    on_exit(fn -> Application.delete_env(:awardflights, :sas_offers_executor) end)
    :ok
  end

  defp mock_executor(output, exit_code) do
    fn _args -> {output, exit_code} end
  end

  defp setup_mock(output, exit_code) do
    Application.put_env(:awardflights, :sas_offers_executor, mock_executor(output, exit_code))
  end

  # Create a valid JWT token for testing
  defp make_jwt(customer_session_id) do
    header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)

    payload =
      Base.url_encode64(~s({"customerSessionId":"#{customer_session_id}","sub":"user"}),
        padding: false
      )

    signature = Base.url_encode64("fake-signature", padding: false)
    "#{header}.#{payload}.#{signature}"
  end

  describe "search_flights/5" do
    test "parses successful response with available flights" do
      response =
        Jason.encode!(%{
          "outboundFlights" => %{
            "F1" => %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => %{
                "ECONOMY" => %{
                  "STANDARD" => %{
                    "products" => %{
                      "O_1" => %{
                        "price" => %{"points" => 17500},
                        "fares" => [
                          %{"bookingClass" => "O", "avlSeats" => 9}
                        ]
                      },
                      "X_1" => %{
                        "price" => %{"points" => 24000},
                        "fares" => [
                          %{"bookingClass" => "X", "avlSeats" => 5}
                        ]
                      }
                    }
                  }
                },
                "BUSINESS" => %{
                  "STANDARD" => %{
                    "products" => %{
                      "Z_1" => %{
                        "price" => %{"points" => 75000},
                        "fares" => [
                          %{"bookingClass" => "Z", "avlSeats" => 2}
                        ]
                      }
                    }
                  }
                }
              }
            }
          }
        })

      setup_mock(response, 0)

      assert {:ok, flights} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "test_cookies",
                 make_jwt("session-123")
               )

      assert length(flights) == 3

      # Check all flights have correct source
      assert Enum.all?(flights, fn f -> f.source == :offers end)

      # Find each flight type
      economy_o = Enum.find(flights, fn f -> f.booking_class == "O" end)
      economy_x = Enum.find(flights, fn f -> f.booking_class == "X" end)
      business_z = Enum.find(flights, fn f -> f.booking_class == "Z" end)

      assert economy_o.departure == "GOT"
      assert economy_o.arrival == "CDG"
      assert economy_o.date == "2026-01-23"
      assert economy_o.cabin == "Economy"
      assert economy_o.available_tickets == 9
      assert economy_o.points == 17500

      assert economy_x.points == 24000
      assert economy_x.available_tickets == 5

      assert business_z.cabin == "Business"
      assert business_z.points == 75000
      assert business_z.available_tickets == 2
    end

    test "filters out products with zero available seats" do
      response =
        Jason.encode!(%{
          "outboundFlights" => %{
            "F1" => %{
              "origin" => %{"code" => "ARN"},
              "destination" => %{"code" => "LHR"},
              "cabins" => %{
                "ECONOMY" => %{
                  "STANDARD" => %{
                    "products" => %{
                      "O_1" => %{
                        "price" => %{"points" => 17500},
                        "fares" => [
                          %{"bookingClass" => "O", "avlSeats" => 0}
                        ]
                      },
                      "X_1" => %{
                        "price" => %{"points" => 24000},
                        "fares" => [
                          %{"bookingClass" => "X", "avlSeats" => 3}
                        ]
                      }
                    }
                  }
                }
              }
            }
          }
        })

      setup_mock(response, 0)

      assert {:ok, flights} =
               SasOffersApi.search_flights(
                 "ARN",
                 "LHR",
                 "2026-02-01",
                 "cookies",
                 make_jwt("sess")
               )

      assert length(flights) == 1
      assert hd(flights).booking_class == "X"
    end

    test "filters out mixed cash+points pricing (basePrice > 0)" do
      response =
        Jason.encode!(%{
          "outboundFlights" => %{
            "F1" => %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => %{
                "ECONOMY" => %{
                  "STANDARD" => %{
                    "products" => %{
                      # Mixed pricing - has basePrice, should be filtered
                      "mixed_1" => %{
                        "price" => %{"points" => 31722, "basePrice" => 1049.0},
                        "fares" => [
                          %{"bookingClass" => "M", "avlSeats" => 9}
                        ]
                      },
                      # Mixed pricing - another with basePrice, should be filtered
                      "mixed_2" => %{
                        "price" => %{"points" => 43197, "basePrice" => 1499.0},
                        "fares" => [
                          %{"bookingClass" => "Y", "avlSeats" => 5}
                        ]
                      }
                    }
                  },
                  "ECONOMY BONUS" => %{
                    "products" => %{
                      # Points-only - basePrice is 0, should be included
                      "award_1" => %{
                        "price" => %{"points" => 10000, "basePrice" => 0.0},
                        "fares" => [
                          %{"bookingClass" => "O", "avlSeats" => 3}
                        ]
                      }
                    }
                  }
                }
              }
            }
          }
        })

      setup_mock(response, 0)

      assert {:ok, flights} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-02-01",
                 "cookies",
                 make_jwt("sess")
               )

      # Only the points-only award (basePrice == 0) should be included
      assert length(flights) == 1
      assert hd(flights).points == 10000
      assert hd(flights).booking_class == "O"
    end

    test "returns empty list when no flights available" do
      response = Jason.encode!(%{"outboundFlights" => %{}})
      setup_mock(response, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "NYC",
                 "2026-03-01",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns auth_expired on 401 status code in JSON" do
      response = Jason.encode!(%{"statusCode" => 401, "message" => "Unauthorized"})
      setup_mock(response, 22)

      assert {:error, :auth_expired} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "bad_cookies",
                 make_jwt("sess")
               )
    end

    test "returns rate_limited on 429 with remaining time" do
      response =
        Jason.encode!(%{
          "statusCode" => 429,
          "payload" => %{"remainingTime" => 3541, "message" => "Too many requests"}
        })

      setup_mock(response, 22)

      assert {:error, {:rate_limited, 3541}} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns cloudflare_blocked on HTML response containing cloudflare" do
      html_response = """
      <!DOCTYPE html>
      <html>
      <head><title>Attention Required! | Cloudflare</title></head>
      <body>Please complete the security check to access www.sas.se</body>
      </html>
      """

      setup_mock(html_response, 22)

      assert {:error, :cloudflare_blocked} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns curl_failed on non-zero exit code that's not 22 or 28" do
      setup_mock("Connection refused", 7)

      assert {:error, {:curl_failed, 7, "Connection refused"}} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns timeout on exit code 28" do
      setup_mock("Operation timed out", 28)

      assert {:error, :timeout} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns json_parse_error on invalid JSON" do
      setup_mock("not valid json {{{", 0)

      assert {:error, {:json_parse_error, "not valid json {{{"}} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "builds URL with correct query parameters" do
      response = Jason.encode!(%{"outboundFlights" => %{}})

      # Capture the args passed to the executor
      Application.put_env(:awardflights, :sas_offers_executor, fn args ->
        send(self(), {:captured_args, args})
        {response, 0}
      end)

      SasOffersApi.search_flights(
        "GOT",
        "CDG",
        "2026-01-23",
        "cookies",
        make_jwt("my-session-id")
      )

      assert_receive {:captured_args, args}
      url = List.last(args)
      # Verify all required parameters are present
      assert String.contains?(url, "pos=se")
      assert String.contains?(url, "channel=web")
      assert String.contains?(url, "displayType=upsell")
      assert String.contains?(url, "adt=1")
      assert String.contains?(url, "yth=0")
    end

    test "builds correct URL with date format conversion" do
      response = Jason.encode!(%{"outboundFlights" => %{}})

      Application.put_env(:awardflights, :sas_offers_executor, fn args ->
        send(self(), {:captured_args, args})
        {response, 0}
      end)

      SasOffersApi.search_flights("GOT", "CDG", "2026-06-15", "cookies", make_jwt("sess"))

      assert_receive {:captured_args, args}
      url = List.last(args)

      # Date should be converted from YYYY-MM-DD to YYYYMMDD
      assert String.contains?(url, "outDate=20260615")
      assert String.contains?(url, "from=GOT")
      assert String.contains?(url, "to=CDG")
      assert String.contains?(url, "bookingFlow=points")
    end

    test "passes cookies in the request" do
      response = Jason.encode!(%{"outboundFlights" => %{}})
      test_cookies = "__cf_bm=abc123; session_id=test; __session=xyz"

      Application.put_env(:awardflights, :sas_offers_executor, fn args ->
        send(self(), {:captured_args, args})
        {response, 0}
      end)

      SasOffersApi.search_flights("GOT", "CDG", "2026-01-23", test_cookies, make_jwt("sess"))

      assert_receive {:captured_args, args}
      # Find the cookie header
      cookie_idx = Enum.find_index(args, fn arg -> arg == "cookie: #{test_cookies}" end)
      assert cookie_idx != nil
    end

    test "handles missing products gracefully" do
      response =
        Jason.encode!(%{
          "outboundFlights" => %{
            "F1" => %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => %{
                "ECONOMY" => %{
                  "STANDARD" => %{}
                }
              }
            }
          }
        })

      setup_mock(response, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "handles missing fares gracefully" do
      response =
        Jason.encode!(%{
          "outboundFlights" => %{
            "F1" => %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => %{
                "ECONOMY" => %{
                  "STANDARD" => %{
                    "products" => %{
                      "O_1" => %{
                        "price" => %{"points" => 17500},
                        "fares" => []
                      }
                    }
                  }
                }
              }
            }
          }
        })

      setup_mock(response, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "handles empty auth_token gracefully" do
      response = Jason.encode!(%{"outboundFlights" => %{}})
      setup_mock(response, 0)

      # Should not crash with empty auth token
      assert {:ok, []} = SasOffersApi.search_flights("GOT", "CDG", "2026-01-23", "cookies", "")
    end

    test "works without explicit auth_token" do
      response = Jason.encode!(%{"outboundFlights" => %{}})
      jwt = make_jwt("extracted-session-id")
      cookies = "__cf_bm=abc123; LOGIN_AUTH=#{jwt}; session_id=xyz"

      Application.put_env(:awardflights, :sas_offers_executor, fn args ->
        send(self(), {:captured_args, args})
        {response, 0}
      end)

      # Call without explicit auth_token - should still work
      assert {:ok, []} = SasOffersApi.search_flights("GOT", "CDG", "2026-01-23", cookies)

      assert_receive {:captured_args, args}
      url = List.last(args)
      assert String.contains?(url, "bookingFlow=points")
    end

    test "includes browser-like headers in request" do
      response = Jason.encode!(%{"outboundFlights" => %{}})
      cookies = "__cf_bm=abc123; session_id=xyz"

      Application.put_env(:awardflights, :sas_offers_executor, fn args ->
        send(self(), {:captured_args, args})
        {response, 0}
      end)

      SasOffersApi.search_flights("GOT", "CDG", "2026-01-23", cookies, make_jwt("sess"))

      assert_receive {:captured_args, args}
      args_str = Enum.join(args, " ")
      # Verify browser-like headers are present
      assert String.contains?(args_str, "origin: https://www.sas.se")
      assert String.contains?(args_str, "referer: https://www.sas.se/book/flights")
      assert String.contains?(args_str, "sec-fetch-mode: cors")
    end

    test "strips Docker platform warning from output before parsing" do
      json = Jason.encode!(%{"outboundFlights" => %{}})
      # Simulates the warning Docker emits on ARM Macs running amd64 images
      output_with_warning = """
      WARNING: The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8) and no specific platform was requested
      #{json}
      """

      setup_mock(output_with_warning, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "returns empty list when SAS returns errors array (no availability)" do
      response =
        Jason.encode!(%{
          "errors" => [
            %{
              "errorCode" => "225050",
              "errorMessage" =>
                "Unfortunately, we can't offer any availability for selected cities & bookingType"
            }
          ],
          "links" => []
        })

      setup_mock(response, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "LAX",
                 "2026-06-03",
                 "cookies",
                 make_jwt("sess")
               )
    end

    test "handles Docker warning combined with SAS errors response" do
      json =
        Jason.encode!(%{
          "errors" => [
            %{"errorCode" => "225050", "errorMessage" => "No availability"}
          ],
          "links" => []
        })

      output_with_warning =
        "WARNING: The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8) and no specific platform was requested\n#{json}"

      setup_mock(output_with_warning, 0)

      assert {:ok, []} =
               SasOffersApi.search_flights(
                 "GOT",
                 "LAX",
                 "2026-06-03",
                 "cookies",
                 make_jwt("sess")
               )
    end
  end
end
