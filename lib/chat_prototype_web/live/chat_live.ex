defmodule ChatPrototypeWeb.ChatLive do
  use ChatPrototypeWeb, :live_view

  import ChatPrototypeWeb.ChatMenuComponent
  import ChatPrototypeWeb.MainRoomComponent
  import ChatPrototypeWeb.LoginComponent

  alias ChatPrototype.Server
  alias ChatPrototype.Server.Room

  @main_room %{uuid: "main-room", name: "Main Room", unread_messages_count: 0}

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    all_rooms = get_all_rooms()

    {:ok,
     assign(socket,
       stage: :welcome,
       user_name: "",
       form: to_form(%{"user_name" => ""}),
       all_rooms: all_rooms,
       selected_room: @main_room,
       active_rooms: [@main_room]
     )}
  end

  @impl true
  @spec render(Socket.assigns()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    case assigns.stage do
      :welcome ->
        ~H"""
        <.render_login form={@form} />
        """

      :rooms_list ->
        ~H"""
        <div class="flex flex-row flex-1">
          <.render_chat_menu active_rooms={@active_rooms} />

          <%= if @selected_room.uuid == "main-room" do %>
            <.render_main_room active_rooms={@active_rooms} all_rooms={@all_rooms} />
          <% else %>
            <.live_component
              module={ChatPrototypeWeb.ChatRoomComponent}
              id={@selected_room.uuid}
              name={@selected_room.name}
            />
          <% end %>
        </div>
        """
    end
  end

  @impl true
  @spec handle_event(binary(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("sign_in", %{"user_name" => user_name}, socket) do
    {:noreply,
     assign(socket,
       stage: :rooms_list,
       user_name: user_name
     )}
  end

  def handle_event("join_room", %{"id" => room_uuid}, %{assigns: assigns} = socket) do
    active_room =
      assigns.all_rooms |> find_room_in_list(room_uuid) |> Map.merge(%{unread_messages_count: 0})

    new_active_rooms_list = Enum.concat(assigns.active_rooms, [active_room])

    subscribe_room(active_room.uuid, new_active_rooms_list, assigns.user_name)

    {:noreply, assign(socket, active_rooms: new_active_rooms_list)}
  end

  def handle_event("select_room", %{"id" => room_uuid}, %{assigns: assigns} = socket) do
    selected_room = find_room_in_list(assigns.active_rooms, room_uuid)

    active_rooms =
      Enum.map(assigns.active_rooms, fn room ->
        if room.uuid == room_uuid do
          %{room | unread_messages_count: 0}
        else
          room
        end
      end)

    if room_uuid == @main_room.uuid do
      all_rooms = get_all_rooms()

      {:noreply,
       assign(socket,
         active_rooms: active_rooms,
         all_rooms: all_rooms,
         selected_room: selected_room
       )}
    else
      room_messages = Room.get_messages(selected_room.name)
      send_update(ChatPrototypeWeb.ChatRoomComponent, id: room_uuid, new_messages: room_messages)

      {:noreply, assign(socket, active_rooms: active_rooms, selected_room: selected_room)}
    end
  end

  def handle_event("send_message", %{"text" => text}, socket) do
    ChatPrototypeWeb.Endpoint.broadcast(socket.assigns.selected_room.uuid, "new-message", %{
      uuid: UUID.uuid4(),
      user: socket.assigns.user_name,
      text: text
    })

    {:noreply, socket}
  end

  @impl true
  @spec handle_info(
          %{
            :event => String.t(),
            :payload => map(),
            :topic => String.t()
          },
          Socket.t()
        ) :: {:noreply, Socket.t()}
  def handle_info(%{event: "new-message", payload: message, topic: room_uuid}, socket) do
    if socket.assigns.selected_room.uuid == room_uuid do
      send_update(ChatPrototypeWeb.ChatRoomComponent, id: room_uuid, new_messages: [message])
      {:noreply, socket}
    else
      active_rooms =
        Enum.map(socket.assigns.active_rooms, fn room ->
          if room.uuid == room_uuid do
            unread_messages_count = room.unread_messages_count + 1
            %{room | unread_messages_count: unread_messages_count}
          else
            room
          end
        end)

      {:noreply, assign(socket, active_rooms: active_rooms)}
    end
  end

  def handle_info(
        %{event: "presence_diff", payload: %{joins: joins, leaves: leaves}, topic: room_uuid},
        socket
      ) do
    join_message =
      joins
      |> Map.keys()
      |> Enum.map(fn username ->
        %{uuid: UUID.uuid4(), user: username, text: "#{username} joinned the chat."}
      end)

    leave_message =
      leaves
      |> Map.keys()
      |> Enum.map(fn username ->
        %{uuid: UUID.uuid4(), user: username, text: "#{username} left the chat."}
      end)

    send_update(ChatPrototypeWeb.ChatRoomComponent,
      id: room_uuid,
      new_messages: Enum.concat(join_message, leave_message)
    )

    {:noreply, socket}
  end

  @spec subscribe_room(String.t(), list(), String.t()) :: any()
  defp subscribe_room(room_uuid, active_rooms, user_name) do
    active_rooms
    |> Enum.any?(fn room -> room.uuid == room_uuid end)
    |> if do
      ChatPrototypeWeb.Endpoint.subscribe(room_uuid)
      ChatPrototypeWeb.Presence.track(self(), room_uuid, user_name, %{})
    end
  end

  @spec find_room_in_list(list(), String.t()) :: map()
  defp find_room_in_list(list, uuid) do
    Enum.find(list, fn room -> room.uuid == uuid end)
  end

  @spec get_all_rooms() :: list()
  defp get_all_rooms() do
    rooms = Server.list_rooms()
    Enum.concat([@main_room], rooms)
  end
end
