import "./App.css";
import { TodoProvider } from "./contexts/TodoContext";
import { TodoList } from "./components/TodoList";
import { AddTodo } from "./components/AddTodo";
import { pbjs } from "../../../pbjsClient/pbjsClient";

function App() {
  // The typed client (pbjsClient/) rather than raw `window.pbjs`: it waits for
  // the bridge itself, so this runs correctly however early the component
  // mounts. Returning a value is the same as calling event.success() with it.
  pbjs.handleAll("testSuccess", (_event, params, data) => ({
    message: "Success from " + pbjs.windowName + "  yaaay " + data,
    data: params,
  }));

  return (
    <TodoProvider>
      <div className="app">
        <h1>Todo List</h1>
        <AddTodo />
        <TodoList />
      </div>
    </TodoProvider>
  );
}

export default App;
